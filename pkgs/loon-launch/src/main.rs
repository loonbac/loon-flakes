use glib::clone;
use gtk4::gdk::Key;
use gtk4::prelude::*;
use gtk4::{
    Application, ApplicationWindow, Entry, EventControllerFocus, EventControllerKey, IconLookupFlags,
    IconTheme, Image, Label, ListBoxRow, Orientation,
};
use libadwaita as adw;
use std::cell::RefCell;
use std::fs;
use std::path::Path;
use std::rc::Rc;

const BANNER_PATH: &str = "/home/loonbac/Descargas/cl_aesthetic_mix58.jpg";

// ---------- Modelo de una app/acción ----------
#[derive(Clone)]
struct Item {
    name: String,
    exec: String, // comando a ejecutar al activar
    icon: String,
}

// ---------- Cargar apps desde .desktop files ----------
fn load_apps() -> Vec<Item> {
    let mut apps = Vec::new();
    let dirs = [
        "/run/current-system/sw/share/applications",
        "/run/current-system/sw/share/applications/kde",
        "/home/loonbac/.local/share/applications",
        "/usr/share/applications",
    ];

    for dir in dirs {
        if !Path::new(dir).is_dir() {
            continue;
        }
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                    continue;
                }
                if let Some(item) = parse_desktop(&path) {
                    apps.push(item);
                }
            }
        }
    }

    apps.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    apps.dedup_by(|a, b| a.name == b.name && a.exec == b.exec);
    apps
}

fn parse_desktop(path: &Path) -> Option<Item> {
    let content = fs::read_to_string(path).ok()?;
    let mut name = None;
    let mut exec = None;
    let mut icon = String::new();
    let mut in_entry = false;
    let mut no_display = false;
    let mut terminal = false;

    for line in content.lines() {
        let line = line.trim();
        if line == "[Desktop Entry]" {
            in_entry = true;
            continue;
        }
        if in_entry && line.starts_with('[') && !line.starts_with("[Desktop Entry]") {
            break;
        }
        if !in_entry {
            continue;
        }
        if let Some(v) = line.strip_prefix("Name=") {
            name = Some(v.to_string());
        } else if let Some(v) = line.strip_prefix("Exec=") {
            exec = Some(v.to_string());
        } else if let Some(v) = line.strip_prefix("Icon=") {
            icon = v.to_string();
        } else if line.starts_with("NoDisplay=true") {
            no_display = true;
        } else if line.starts_with("Terminal=true") {
            terminal = true;
        }
    }

    let name = name?;
    let mut exec = exec?;
    if no_display || exec.is_empty() {
        return None;
    }

    // Limpiar campos de Exec según la spec de freedesktop.
    exec = exec
        .split_whitespace()
        .filter(|t| !t.starts_with('%'))
        .collect::<Vec<_>>()
        .join(" ");

    if terminal {
        exec = format!("ghostty -e {}", exec);
    }

    Some(Item { name, exec, icon })
}

// ---------- Celda del grid: icono arriba, nombre debajo ----------
fn make_cell(item: &Item) -> ListBoxRow {
    let cell = ListBoxRow::new();
    let vbox = gtk4::Box::new(Orientation::Vertical, 6);
    vbox.set_margin_top(12);
    vbox.set_margin_bottom(12);
    vbox.set_margin_start(14);
    vbox.set_margin_end(14);
    vbox.set_valign(gtk4::Align::Center);

    let image = Image::new();
    if let Some(icon) = resolve_icon(&item.icon) {
        image.set_paintable(Some(&icon));
    }
    image.set_pixel_size(44);
    image.set_valign(gtk4::Align::Center);
    image.set_halign(gtk4::Align::Center);
    vbox.append(&image);

    let label = Label::new(Some(&item.name));
    label.set_xalign(0.5);
    label.set_justify(gtk4::Justification::Center);
    label.set_max_width_chars(12);
    label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    vbox.append(&label);

    cell.set_child(Some(&vbox));
    cell
}

fn resolve_icon(icon: &str) -> Option<gtk4::IconPaintable> {
    let theme = IconTheme::new();
    // Si el icono es una ruta absoluta, gtk4 lo carga directo; si es un
    // nombre del tema, solo renderiza si existe (evita el icono "missing").
    if !icon.starts_with('/') && !theme.has_icon(icon) {
        return None;
    }
    Some(theme.lookup_icon(
        icon,
        &[],
        28,
        1,
        gtk4::TextDirection::None,
        IconLookupFlags::FORCE_SYMBOLIC
            | IconLookupFlags::FORCE_REGULAR
            | IconLookupFlags::PRELOAD,
    ))
}


fn power_actions() -> Vec<Item> {
    vec![
        Item { name: "Apagar".to_string(), exec: "systemctl poweroff".to_string(), icon: "system-shutdown".to_string() },
        Item { name: "Reiniciar".to_string(), exec: "systemctl reboot".to_string(), icon: "system-reboot".to_string() },
        Item { name: "Hibernar".to_string(), exec: "systemctl hibernate".to_string(), icon: "system-suspend-hibernate".to_string() },
        Item { name: "Suspender".to_string(), exec: "systemctl suspend".to_string(), icon: "system-suspend".to_string() },
        Item { name: "Bloquear".to_string(), exec: "loginctl lock-session".to_string(), icon: "system-lock-screen".to_string() },
    ]
}

// ---------- UI ----------
fn build_ui(app: &Application) {
    // Modo oscuro global de libadwaita.
    let style = adw::StyleManager::default();
    style.set_color_scheme(adw::ColorScheme::ForceDark);

    let window = ApplicationWindow::builder()
        .application(app)
        .title("loon-launch")
        .default_width(760)
        .default_height(520)
        .decorated(false)
        .build();

    let vbox = gtk4::Box::new(Orientation::Vertical, 0);
    window.set_child(Some(&vbox));

    // ---------- Banner: imagen de fondo con la búsqueda centrada encima ----------
    let entry = Entry::new();
    entry.set_placeholder_text(Some("Buscar app… (escribe '>' para acciones de poder)"));
    entry.add_css_class("search-entry");
    entry.set_margin_top(12);
    entry.set_margin_bottom(8);
    entry.set_margin_start(60);
    entry.set_margin_end(60);
    entry.set_hexpand(true);
    vbox.append(&entry);

    let banner_pic = gtk4::Picture::for_filename(BANNER_PATH);
    banner_pic.set_content_fit(gtk4::ContentFit::Cover);
    banner_pic.set_hexpand(true);
    banner_pic.set_height_request(140);
    banner_pic.add_css_class("banner-img");
    vbox.append(&banner_pic);

    // ---------- Grid de apps ----------
    let grid = gtk4::Grid::new();
    grid.set_row_spacing(2);
    grid.set_column_spacing(2);
    grid.set_halign(gtk4::Align::Center);
    let scrolled = gtk4::ScrolledWindow::builder().child(&grid).hexpand(true).vexpand(true).build();
    vbox.append(&scrolled);

    let all_apps = load_apps();
    let power = power_actions();

    fn repopulate(
        grid: &gtk4::Grid,
        all_apps: &[Item],
        power: &[Item],
        query: &str,
        sel: &Rc<RefCell<i32>>,
    ) -> Vec<Item> {
        while let Some(child) = grid.first_child() {
            grid.remove(&child);
        }

        let q = query.to_lowercase();
        let mut shown: Vec<Item> = Vec::new();

        if q.starts_with('>') {
            // Modo poder: filtro por el texto después de '>'.
            let filter = q[1..].trim().to_string();
            for p in power {
                if filter.is_empty() || p.name.to_lowercase().contains(&filter) {
                    shown.push(p.clone());
                }
            }
        } else {
            for app in all_apps {
                if app.name.to_lowercase().contains(&q) {
                    shown.push(app.clone());
                }
            }
        }

        let cols = 7;
        for (i, item) in shown.iter().enumerate() {
            let cell = make_cell(item);
            grid.attach(&cell, (i % cols) as i32, (i / cols) as i32, 1, 1);
            if i as i32 == *sel.borrow() {
                // La celda activa queda marcada como seleccionada.
                cell.add_css_class("selected");
            }
        }
        // Si el índice previo quedó fuera de rango, seleccionar el primero.
        if shown.is_empty() {
            *sel.borrow_mut() = -1;
        } else if *sel.borrow() >= shown.len() as i32 {
            *sel.borrow_mut() = 0;
            if let Some(child) = grid.first_child() {
                if let Some(row) = child.downcast::<ListBoxRow>().ok() {
                    row.add_css_class("selected");
                }
            }
        }

        shown
    }

    let sel_idx = Rc::new(RefCell::new(0));
    let current_items = Rc::new(RefCell::new(repopulate(
        &grid,
        &all_apps,
        &power,
        "",
        &sel_idx,
    )));

    entry.connect_changed(clone!(
        #[strong]
        grid,
        #[strong]
        entry,
        #[strong]
        all_apps,
        #[strong]
        power,
        #[strong]
        current_items,
        #[strong]
        sel_idx,
        move |_| {
            let q = entry.text().to_string();
            *current_items.borrow_mut() = repopulate(&grid, &all_apps, &power, &q, &sel_idx);
        },
    ));

    let run_selected = clone!(
        #[strong]
        window,
        #[strong]
        current_items,
        #[strong]
        sel_idx,
        move || {
            let items = current_items.borrow();
            let idx = *sel_idx.borrow();
            if idx >= 0 && (idx as usize) < items.len() {
                let item = &items[idx as usize];
                // Ejecutar el comando de forma independiente.
                let exec = item.exec.clone();
                std::thread::spawn(move || {
                    let _ = std::process::Command::new("sh").arg("-c").arg(&exec).spawn();
                });
            }
            window.close();
        },
    );

    // Navegación 100% por teclado: Enter ejecuta, flechas mueven la selección,
    // Escape cierra. El mouse está deshabilitado en el listado.
    entry.connect_activate(clone!(
        #[strong]
        run_selected,
        move |_| {
            run_selected();
        },
    ));

    let key_controller = EventControllerKey::new();
    key_controller.connect_key_pressed(clone!(
        #[strong]
        grid,
        #[strong]
        window,
        #[strong]
        sel_idx,
        move |_, key, _, _| {
            let total = || {
                let mut n = 0;
                let mut child = grid.first_child();
                while let Some(c) = child {
                    n += 1;
                    child = c.next_sibling();
                }
                n
            };
            // Mover la selección y repintar la clase "selected".
            let move_sel = |delta: i32| {
                let t = total();
                if t == 0 {
                    return;
                }
                let mut idx = *sel_idx.borrow();
                if idx < 0 {
                    idx = 0;
                } else {
                    idx += delta;
                    if idx < 0 {
                        idx = 0;
                    } else if idx >= t {
                        idx = t - 1;
                    }
                }
                *sel_idx.borrow_mut() = idx;
                let children = grid.observe_children();
                for i in 0..children.n_items() {
                    if let Some(obj) = children.item(i) {
                        if let Ok(w) = obj.downcast::<gtk4::Widget>() {
                            if i as i32 == idx {
                                w.add_css_class("selected");
                            } else {
                                w.remove_css_class("selected");
                            }
                        }
                    }
                }
            };
            let cols = 7;
            match key {
                Key::Escape => {
                    window.close();
                    glib::Propagation::Stop
                }
                Key::Down => {
                    move_sel(cols);
                    glib::Propagation::Stop
                }
                Key::Up => {
                    move_sel(-cols);
                    glib::Propagation::Stop
                }
                Key::Right => {
                    move_sel(1);
                    glib::Propagation::Stop
                }
                Key::Left => {
                    move_sel(-1);
                    glib::Propagation::Stop
                }
                _ => glib::Propagation::Proceed,
            }
        },
    ));
    // En fase de captura para que las flechas lleguen antes que el Entry.
    key_controller.set_propagation_phase(gtk4::PropagationPhase::Capture);
    window.add_controller(key_controller);

    // Cerrar si la ventana pierde el foco (click fuera de ella).
    let focus_controller = EventControllerFocus::new();
    focus_controller.connect_leave(clone!(
        #[strong]
        window,
        move |_| {
            window.close();
        },
    ));
    window.add_controller(focus_controller);

    // ---------- Estilos ----------
    let css = gtk4::CssProvider::new();
    css.load_from_data(
        ".banner-img { border-radius: 18px; }
         entry.search-entry {
             border-radius: 16px;
             background-color: rgba(22, 22, 30, 0.94);
             color: white;
             caret-color: white;
             border: 1px solid rgba(255, 255, 255, 0.28);
             padding: 10px 16px;
             font-size: 15px;
         }
         entry.search-entry selection {
             background-color: rgba(88, 101, 242, 0.9);
             color: white;
         }
         .selected {
             background-color: rgba(88, 101, 242, 0.35);
             border-radius: 12px;
         }",
    );
    window.style_context().add_provider(&css, gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION);

    // El launcher se opera solo con el teclado: niri le da el foco
    // al spawnearlo, y el entry lo toma al presentar.
    window.present();
    entry.grab_focus();
}

fn main() {
    let app = Application::builder().application_id("dev.loonbac.loonlaunch").build();
    app.connect_activate(build_ui);
    app.run();
}
