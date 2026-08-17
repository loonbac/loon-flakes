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
use crate::models::Item;
use crate::ui::banner::build_banner;
use crate::ui::grid::{build_grid, GridRefs};
use crate::ui::keys::setup_key_controller;
use crate::ui::styles::setup_styles;
use crate::wallpapers::wallpapers;
use std::cell::RefCell;
use std::rc::Rc;

/// Ventana del daemon y guard de vida de la app, conservados entre toggles.
/// thread_local es seguro porque todo corre en el hilo de GTK; guardar la
/// ventana en qdata con ptr::read corrompía el refcount del wrapper.
thread_local! {
    static WINDOW: RefCell<Option<gtk4::ApplicationWindow>> = RefCell::new(None);
    // Refs del grid para repoblar al presentar (misma vida que la ventana).
    static GRID_REFS: RefCell<Option<GridRefs>> = RefCell::new(None);
    // Apps cacheadas para el closure de búsqueda (actualizadas en cada apertura).
    static ALL_APPS: RefCell<Option<Rc<RefCell<Vec<Item>>>>> = RefCell::new(None);
    static POWER: RefCell<Option<Rc<RefCell<Vec<Item>>>>> = RefCell::new(None);
    // Fondos de pantalla (videos + imágenes del backdrop).
    static WALLPAPERS: RefCell<Option<Rc<RefCell<Vec<Item>>>>> = RefCell::new(None);
    // Items mostrados actualmente (los que ejecuta `run_selected`).
    static CURRENT_ITEMS: RefCell<Option<Rc<RefCell<Vec<Item>>>>> = RefCell::new(None);
    // Índice de selección compartido con la navegación de teclado.
    static SEL_IDX: RefCell<Option<Rc<RefCell<i32>>>> = RefCell::new(None);
    // El guard no es Send/Sync ni Clone: se retiene aquí aparte.
    static HOLD: RefCell<Option<gtk4::gio::ApplicationHoldGuard>> = RefCell::new(None);
}

/// Arma la UI (oculta) la primera vez y alterna visibilidad en cada activate.
/// Si `wallpaper_mode` es true, abre directo en el selector de fondos ('#').
pub fn build_ui(app: &gtk4::Application, wallpaper_mode: bool) {
    let fresh_apps = load_apps();
    let fresh_power = power_actions();
    let fresh_wallpapers = wallpapers();

    if let Some(win) = WINDOW.with(|w| w.borrow().clone()) {
        ALL_APPS.with(|a| {
            if let Some(apps_rc) = a.borrow().as_ref() {
                *apps_rc.borrow_mut() = fresh_apps;
            }
        });
        POWER.with(|p| {
            if let Some(power_rc) = p.borrow().as_ref() {
                *power_rc.borrow_mut() = fresh_power;
            }
        });
        WALLPAPERS.with(|w| {
            if let Some(wp_rc) = w.borrow().as_ref() {
                *wp_rc.borrow_mut() = fresh_wallpapers;
            }
        });
        // Ya construida: toggle. Si estaba visible, ocultar; si no, mostrar.
        if win.is_visible() {
            win.hide();
        } else {
            present_and_focus(&win, wallpaper_mode);
        }
        return;
    }

    let all_apps = Rc::new(RefCell::new(fresh_apps));
    let power = Rc::new(RefCell::new(fresh_power));
    let wallpapers = Rc::new(RefCell::new(fresh_wallpapers));
    ALL_APPS.with(|a| *a.borrow_mut() = Some(all_apps.clone()));
    POWER.with(|p| *p.borrow_mut() = Some(power.clone()));
    WALLPAPERS.with(|w| *w.borrow_mut() = Some(wallpapers.clone()));

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
    GRID_REFS.with(|g| *g.borrow_mut() = Some(grid_refs.clone()));

    // Estado de selección y de items actuales.
    let sel_idx = Rc::new(RefCell::new(0));
    SEL_IDX.with(|s| *s.borrow_mut() = Some(sel_idx.clone()));
    let current_items = Rc::new(RefCell::new(grid_refs.repopulate(
        &all_apps.borrow(),
        &power.borrow(),
        &wallpapers.borrow(),
        if wallpaper_mode { "#" } else { "" },
        &sel_idx,
    )));
    CURRENT_ITEMS.with(|c| *c.borrow_mut() = Some(current_items.clone()));

    // Al escribir, re-filtrar el grid.
    entry.connect_changed({
        let grid_refs = grid_refs.clone();
        let all_apps = all_apps.clone();
        let power = power.clone();
        let wallpapers = wallpapers.clone();
        let current_items = current_items.clone();
        let sel_idx = sel_idx.clone();
        move |entry| {
            let q = entry.text().to_string();
            let apps = all_apps.borrow();
            let power = power.borrow();
            let wallpapers = wallpapers.borrow();
            *current_items.borrow_mut() =
                grid_refs.repopulate(&apps, &power, &wallpapers, &q, &sel_idx);
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
/// Recarga la lista de apps primero: así las apps nuevas instaladas con
/// rebuild aparecen sin reiniciar el daemon. Se repuebla el grid de forma
/// explícita (no depende del signal `changed` de la entry: si la búsqueda
/// ya estaba vacía, `set_text("")` no dispara el signal y el grid
/// conservaría los items viejos).
fn present_and_focus(window: &gtk4::ApplicationWindow, wallpaper_mode: bool) {
    let fresh_apps = load_apps();
    let power = power_actions();
    let fresh_wallpapers = wallpapers();
    ALL_APPS.with(|a| {
        if let Some(apps_rc) = a.borrow().as_ref() {
            *apps_rc.borrow_mut() = fresh_apps;
        }
    });
    WALLPAPERS.with(|w| {
        if let Some(wp_rc) = w.borrow().as_ref() {
            *wp_rc.borrow_mut() = fresh_wallpapers;
        }
    });
    let apps = ALL_APPS.with(|a| a.borrow().as_ref().map(|r| r.borrow().clone()).unwrap_or_default());
    let wallpapers = WALLPAPERS.with(|w| {
        w.borrow()
            .as_ref()
            .map(|r| r.borrow().clone())
            .unwrap_or_default()
    });
    let sel_idx = SEL_IDX.with(|s| {
        s.borrow()
            .as_ref()
            .cloned()
            .unwrap_or_else(|| Rc::new(RefCell::new(0)))
    });
    let shown = GRID_REFS.with(|g| {
        g.borrow()
            .as_ref()
            .map(|grid_refs| {
                grid_refs.repopulate(
                    &apps,
                    &power,
                    &wallpapers,
                    if wallpaper_mode { "#" } else { "" },
                    &sel_idx,
                )
            })
            .unwrap_or_default()
    });
    CURRENT_ITEMS.with(|c| {
        if let Some(items) = c.borrow().as_ref() {
            *items.borrow_mut() = shown;
        }
    });

    window.present();
    // Buscar el Entry (vive dentro del banner) y enfocarlo, con el texto
    // limpio para abrir siempre "fresco".
    let mut stack = vec![window.upcast_ref::<gtk4::Widget>().clone()];
    while let Some(w) = stack.pop() {
        if let Ok(entry) = w.clone().downcast::<gtk4::Entry>() {
            // Limpiar la búsqueda anterior (el signal `changed` re-puebla
            // el grid con todas las apps y resetea la selección). En modo
            // wallpapers dejamos el '#' para filtrar fondos.
            entry.set_text(if wallpaper_mode { "#" } else { "" });
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
