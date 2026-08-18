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
use libadwaita::prelude::*;

use crate::apps::{load_apps, power_actions};
use crate::models::{Item, WIN_H, WIN_W, WP_WIN_W};
use crate::ui::banner::{build_banner, BannerRefs};
use crate::ui::grid::{build_grid, GridRefs};
use crate::ui::keys::setup_key_controller;
use crate::ui::styles::setup_styles;
use crate::wallpapers::wallpapers;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

// Ventana del daemon y guard de vida de la app, conservados entre toggles.
// thread_local es seguro porque todo corre en el hilo de GTK; guardar la
// ventana en qdata con ptr::read corrompía el refcount del wrapper.
thread_local! {
    static WINDOW: RefCell<Option<gtk4::ApplicationWindow>> = RefCell::new(None);
    // Refs del grid para repoblar al presentar (misma vida que la ventana).
    static GRID_REFS: RefCell<Option<GridRefs>> = RefCell::new(None);
    static BANNER: RefCell<Option<Rc<BannerRefs>>> = RefCell::new(None);
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
    // Última animación de opacidad: hay que retenerla o se cancela al dropear.
    static OPACITY_ANIM: RefCell<Option<adw::TimedAnimation>> = RefCell::new(None);
    static HIDING: RefCell<bool> = RefCell::new(false);
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
            hide_window(&win);
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
        .default_width(WIN_W)
        .default_height(WIN_H)
        .resizable(false)
        .decorated(false)
        .build();
    window.add_css_class("loon-launch");
    window.set_default_size(WIN_W, WIN_H);
    window.set_size_request(WIN_W, WIN_H);

    let vbox = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    vbox.set_size_request(WIN_W, WIN_H);
    vbox.set_hexpand(false);
    vbox.set_vexpand(false);
    window.set_child(Some(&vbox));

    // Banner (imagen + entry de búsqueda).
    let banner = Rc::new(build_banner());
    vbox.append(&banner.root);
    BANNER.with(|b| *b.borrow_mut() = Some(banner.clone()));
    let entry = banner.entry.clone();

    // Grid de apps con scroll horizontal.
    let grid_refs = build_grid();
    vbox.append(&grid_refs.scrolled);
    GRID_REFS.with(|g| *g.borrow_mut() = Some(grid_refs.clone()));

    // Estado de selección y de items actuales.
    let sel_idx = Rc::new(RefCell::new(0));
    SEL_IDX.with(|s| *s.borrow_mut() = Some(sel_idx.clone()));
    apply_chrome(&window, &banner, wallpaper_mode);
    let current_items = Rc::new(RefCell::new(grid_refs.repopulate(
        &all_apps.borrow(),
        &power.borrow(),
        &wallpapers.borrow(),
        if wallpaper_mode { "#" } else { "" },
        &sel_idx,
        false,
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
        let banner = banner.clone();
        let window = window.clone();
        move |entry| {
            let q = entry.text().to_string();
            let wallpaper = q.starts_with('#');
            let mode_changed = *grid_refs.wallpaper_mode.borrow() != wallpaper;
            if mode_changed {
                apply_chrome(&window, &banner, wallpaper);
            }
            let apps = all_apps.borrow();
            let power = power.borrow();
            let wallpapers = wallpapers.borrow();
            *current_items.borrow_mut() =
                grid_refs.repopulate(&apps, &power, &wallpapers, &q, &sel_idx, mode_changed);
        }
    });

    // Ejecutar la app seleccionada.
    let run_selected: Rc<dyn Fn()> = {
        let window = window.clone();
        let entry = entry.clone();
        let current_items = current_items.clone();
        let sel_idx = sel_idx.clone();
        Rc::new(move || {
            // Extraer la acción con el borrow ACOTADO: set_text("#") dispara
            // el signal changed, que re-puebla el grid y hace borrow_mut de
            // current_items; si el borrow inmutable siguiera activo aquí,
            // paniquea (BorrowMutError) y la app crashea.
            let action: Option<String> = {
                let items = current_items.borrow();
                let idx = *sel_idx.borrow();
                // El índice seleccionable NO incluye headers: mapear al item real.
                let real = items
                    .iter()
                    .enumerate()
                    .filter(|(_, it)| !it.is_header)
                    .nth(idx.max(0) as usize)
                    .map(|(i, _)| i);
                real.and_then(|i| items.get(i)).map(|it| it.exec.clone())
            };

            match action.as_deref() {
                // Acción interna "Cambiar fondo de pantalla": pasa al modo
                // wallpapers SIN cerrar el launcher (el '#' filtra fondos).
                Some("wallpaper-mode") => {
                    entry.set_text("#");
                    entry.grab_focus();
                }
                // Ejecutar la app seleccionada y ocultar el launcher.
                Some(exec) => {
                    let exec = exec.to_string();
                    std::thread::spawn(move || {
                        let _ = std::process::Command::new("sh").arg("-c").arg(&exec).spawn();
                    });
                    hide_window(&window);
                }
                None => hide_window(&window),
            }
        })
    };
    *grid_refs.activate.borrow_mut() = Some(run_selected.clone());

    let hide: Rc<dyn Fn()> = {
        let window = window.clone();
        Rc::new(move || hide_window(&window))
    };

    // Teclado: flechas, enter, escape, backspace y escritura.
    let keys_state = keys::KeyState {
        grid_refs: grid_refs.clone(),
        entry: entry.clone(),
        sel_idx: sel_idx.clone(),
        hide,
        run_selected,
    };
    setup_key_controller(&window, keys_state);

    // Ocultar si la ventana pierde el foco (click fuera). Un leave
    // inmediato al presentar (p. ej. Entry oculto en modo fondos) no cuenta.
    let focus_controller = gtk4::EventControllerFocus::new();
    focus_controller.connect_leave({
        let window = window.clone();
        move |_| {
            let win = window.clone();
            glib::timeout_add_local_once(Duration::from_millis(120), move || {
                if win.is_visible() && !win.is_active() {
                    hide_window(&win);
                }
            });
        }
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
    HIDING.with(|h| *h.borrow_mut() = false);
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
    BANNER.with(|b| {
        if let Some(banner) = b.borrow().as_ref() {
            apply_chrome(window, banner, wallpaper_mode);
        }
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
                    true,
                )
            })
            .unwrap_or_default()
    });
    CURRENT_ITEMS.with(|c| {
        if let Some(items) = c.borrow().as_ref() {
            *items.borrow_mut() = shown;
        }
    });

    window.set_opacity(0.0);
    window.present();
    fade_opacity(window, 0.0, 1.0, 280, None);
    GRID_REFS.with(|g| {
        if let Some(grid_refs) = g.borrow().as_ref() {
            grid_refs.play_media();
        }
    });
    BANNER.with(|b| {
        if let Some(banner) = b.borrow().as_ref() {
            banner
                .entry
                .set_text(if wallpaper_mode { "#" } else { "" });
            if wallpaper_mode {
                // El banner (y el Entry) están ocultos: enfocar el grid.
                GRID_REFS.with(|g| {
                    if let Some(grid_refs) = g.borrow().as_ref() {
                        grid_refs.scrolled.grab_focus();
                    }
                });
            } else {
                banner.entry.grab_focus();
            }
        }
    });
}

fn apply_chrome(window: &gtk4::ApplicationWindow, banner: &BannerRefs, wallpaper: bool) {
    let w = if wallpaper { WP_WIN_W } else { WIN_W };
    window.set_default_size(w, WIN_H);
    window.set_size_request(w, WIN_H);
    if let Some(child) = window.child() {
        child.set_size_request(w, WIN_H);
    }
    banner.apply_mode(wallpaper);
}

fn hide_window(window: &gtk4::ApplicationWindow) {
    if !window.is_visible() || HIDING.with(|h| *h.borrow()) {
        return;
    }
    HIDING.with(|h| *h.borrow_mut() = true);
    GRID_REFS.with(|g| {
        if let Some(grid_refs) = g.borrow().as_ref() {
            grid_refs.pause_media();
        }
    });
    let from = window.opacity();
    let win = window.clone();
    fade_opacity(
        window,
        from,
        0.0,
        140,
        Some(Box::new(move || {
            win.hide();
            win.set_opacity(1.0);
            HIDING.with(|h| *h.borrow_mut() = false);
        })),
    );
}

fn fade_opacity(
    window: &gtk4::ApplicationWindow,
    from: f64,
    to: f64,
    ms: u32,
    on_done: Option<Box<dyn FnOnce()>>,
) {
    let target = adw::CallbackAnimationTarget::new(glib::clone!(
        #[strong]
        window,
        move |value| {
            window.set_opacity(value);
        }
    ));
    let anim = adw::TimedAnimation::new(window, from, to, ms, target);
    anim.set_easing(if to > from {
        adw::Easing::EaseOutCubic
    } else {
        adw::Easing::EaseInCubic
    });
    if let Some(cb) = on_done {
        let cb = Rc::new(RefCell::new(Some(cb)));
        anim.connect_done(move |_| {
            if let Some(done) = cb.borrow_mut().take() {
                done();
            }
        });
    }
    anim.play();
    OPACITY_ANIM.with(|a| *a.borrow_mut() = Some(anim));
}
