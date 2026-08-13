// Módulo UI: arma la ventana completa del launcher.
//
// El launcher es un daemon: la ventana se construye UNA vez y queda oculta.
// Cada activate (bind Super+Space) alterna visibilidad: si está visible la
// oculta y cierra (esc), si está oculta la presenta y enfoca la búsqueda.
mod banner;
mod grid;
mod keys;
mod styles;

use gtk4::prelude::*;
use libadwaita as adw;

use crate::apps::{load_apps, power_actions};
use crate::ui::banner::build_banner;
use crate::ui::grid::{build_grid, GridRefs};
use crate::ui::keys::setup_key_controller;
use crate::ui::styles::setup_styles;
use std::cell::RefCell;
use std::rc::Rc;

/// Ventana del daemon y guard de vida de la app, conservados entre toggles.
/// thread_local es seguro porque todo corre en el hilo de GTK; guardar la
/// ventana en qdata con ptr::read corrompía el refcount del wrapper.
thread_local! {
    static WINDOW: RefCell<Option<gtk4::ApplicationWindow>> = RefCell::new(None);
    // El guard no es Send/Sync ni Clone: se retiene aquí aparte.
    static HOLD: RefCell<Option<gtk4::gio::ApplicationHoldGuard>> = RefCell::new(None);
}

/// Arma la UI (oculta) la primera vez y alterna visibilidad en cada activate.
pub fn build_ui(app: &gtk4::Application) {
    if let Some(win) = WINDOW.with(|w| w.borrow().clone()) {
        // Ya construida: toggle. Si estaba visible, ocultar; si no, mostrar.
        // Usar hide() (no close(), que destruye la ventana y dejaría el
        // estado apuntando a un objeto finalizado).
        if win.is_visible() {
            win.hide();
        } else {
            present_and_focus(&win);
        }
        return;
    }

    // Primera vez: construir la ventana oculta (no se presenta todavía).
    let style = adw::StyleManager::default();
    style.set_color_scheme(adw::ColorScheme::ForceDark);

    let window = gtk4::ApplicationWindow::builder()
        .application(app)
        .title("loon-launch")
        .default_width(680)
        .default_height(350)
        .resizable(false)
        .decorated(false)
        .build();
    window.set_size_request(680, 350);

    let vbox = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    window.set_child(Some(&vbox));

    // Banner (imagen + entry de búsqueda).
    let (banner, entry) = build_banner();
    vbox.append(&banner);

    // Grid de apps con scroll horizontal.
    let grid_refs = build_grid();
    vbox.append(&grid_refs.scrolled);

    // Cargar apps y poblar el grid inicial.
    let all_apps = load_apps();
    let power = power_actions();

    // Estado de selección y de items actuales.
    let sel_idx = Rc::new(RefCell::new(0));
    let current_items = Rc::new(RefCell::new(grid_refs.repopulate(
        &all_apps,
        &power,
        "",
        &sel_idx,
    )));

    // Al escribir, re-filtrar el grid.
    entry.connect_changed({
        let grid_refs = grid_refs.clone();
        let all_apps = all_apps.clone();
        let power = power.clone();
        let current_items = current_items.clone();
        let sel_idx = sel_idx.clone();
        move |entry| {
            let q = entry.text().to_string();
            *current_items.borrow_mut() = grid_refs.repopulate(&all_apps, &power, &q, &sel_idx);
        }
    });

    // Ejecutar la app seleccionada.
    let run_selected: Rc<dyn Fn()> = {
        let window = window.clone();
        let current_items = current_items.clone();
        let sel_idx = sel_idx.clone();
        Rc::new(move || {
            let items = current_items.borrow();
            let idx = *sel_idx.borrow();
            if idx >= 0 && (idx as usize) < items.len() {
                let item = &items[idx as usize];
                // Ejecutar la app seleccionada y ocultar el launcher.
                let exec = item.exec.clone();
                std::thread::spawn(move || {
                    let _ = std::process::Command::new("sh").arg("-c").arg(&exec).spawn();
                });
            }
            window.hide();
        })
    };

    // Teclado: flechas, enter, escape, backspace y escritura.
    let keys_state = keys::KeyState {
        grid: grid_refs.grid.clone(),
        scrolled: grid_refs.scrolled.clone(),
        entry: entry.clone(),
        window: window.clone(),
        sel_idx: sel_idx.clone(),
        run_selected,
    };
    setup_key_controller(&window, keys_state);

    // Ocultar si la ventana pierde el foco (click fuera de ella).
    let focus_controller = gtk4::EventControllerFocus::new();
    focus_controller.connect_leave({
        let window = window.clone();
        move |_| window.hide()
    });
    window.add_controller(focus_controller);

    setup_styles(&window);

    // Conservar la ventana + guard de vida de la app para los toggles.
    WINDOW.with(|w| *w.borrow_mut() = Some(window.clone()));
    HOLD.with(|h| *h.borrow_mut() = Some(app.hold()));
}

/// Presenta la ventana y enfoca la búsqueda, lista para escribir.
fn present_and_focus(window: &gtk4::ApplicationWindow) {
    window.present();
    // Buscar el Entry (vive dentro del banner) y enfocarlo, con el texto
    // limpio para abrir siempre "fresco".
    let mut stack = vec![window.upcast_ref::<gtk4::Widget>().clone()];
    while let Some(w) = stack.pop() {
        if let Ok(entry) = w.clone().downcast::<gtk4::Entry>() {
            // Limpiar la búsqueda anterior (el signal `changed` re-puebla
            // el grid con todas las apps y resetea la selección).
            entry.set_text("");
            entry.grab_focus();
            return;
        }
        let mut child = w.first_child();
        while let Some(c) = child {
            stack.push(c.clone());
            child = c.next_sibling();
        }
    }
}
