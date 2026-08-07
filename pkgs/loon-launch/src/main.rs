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

// ---------- Modelo de una app/acción ----------
#[derive(Clone)]
struct Item {
    name: String,
    exec: String, // comando a ejecutar al activar
    icon: String,
}

// Número de columnas del grid.
const COLS: usize = 7;

// ---------- Lógica pura (testeable) ----------

/// Filtra las apps según la query. Si empieza por '>', filtra acciones de poder.
fn filter_items(all_apps: &[Item], power: &[Item], query: &str) -> Vec<Item> {
    let q = query.to_lowercase();
    let mut shown: Vec<Item> = Vec::new();

    if q.starts_with('>') {
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
    shown
}

/// Aplica un movimiento de selección (delta en celdas) y devuelve el nuevo índice.
/// - si no hay items devuelve -1
/// - si el índice actual es inválido, se ancla a 0
/// - clampa entre 0 y total-1
fn move_selection(sel: i32, delta: i32, total: usize) -> i32 {
    if total == 0 {
        return -1;
    }
    let mut idx = if sel < 0 { 0 } else { sel + delta };
    if idx < 0 {
        idx = 0;
    } else if idx >= total as i32 {
        idx = total as i32 - 1;
    }
    idx
}

/// Normaliza la selección tras un repopulate: si quedó fuera de rango, 0.
fn normalize_selection(sel: i32, total: usize) -> i32 {
    if total == 0 {
        -1
    } else if sel < 0 || sel >= total as i32 {
        0
    } else {
        sel
    }
}

/// Escribe un carácter en el texto de búsqueda.
fn apply_char(text: &str, c: char) -> String {
    let mut s = text.to_string();
    s.push(c);
    s
}

/// Borra el último carácter.
fn apply_backspace(text: &str) -> String {
    let mut s = text.to_string();
    s.pop();
    s
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

    // ---------- Banner: imagen con la barra superpuesta (Overlay).
    // La imagen es el main child; la barra es overlay child (se pinta
    // encima). Con el provider global el CSS del entry aplica. ----------
    let banner = gtk4::Overlay::new();
    banner.set_hexpand(true);

    let banner_pic = gtk4::Picture::for_filename("/home/loonbac/Descargas/cl_aesthetic_mix58.jpg");
    banner_pic.set_content_fit(gtk4::ContentFit::Cover);
    banner_pic.set_hexpand(true);
    banner_pic.set_height_request(110);
    banner_pic.add_css_class("banner-img");
    banner.set_child(Some(&banner_pic));

    let entry = Entry::new();
    entry.set_placeholder_text(Some("Buscar app… (escribe '>' para acciones de poder)"));
    entry.add_css_class("search-entry");
    entry.set_halign(gtk4::Align::Center);
    entry.set_valign(gtk4::Align::Center);
    entry.set_hexpand(true);
    entry.set_margin_start(40);
    entry.set_margin_end(40);
    banner.add_overlay(&entry);
    banner.set_measure_overlay(&entry, true);

    vbox.append(&banner);

    // ---------- Grid de apps ----------
    let grid = gtk4::Grid::new();
    grid.set_row_spacing(2);
    grid.set_column_spacing(2);
    grid.set_halign(gtk4::Align::Center);
    let scrolled = gtk4::ScrolledWindow::builder().child(&grid).hexpand(true).build();
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

        let shown = filter_items(all_apps, power, query);
        let new_sel = normalize_selection(*sel.borrow(), shown.len());
        *sel.borrow_mut() = new_sel;

        for (i, item) in shown.iter().enumerate() {
            let cell = make_cell(item);
            grid.attach(&cell, (i % COLS) as i32, (i / COLS) as i32, 1, 1);
            if i as i32 == new_sel {
                cell.add_css_class("selected");
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

    // El key controller va en el ENTRY (no en la ventana), en fase de
    // captura: intercepta las flechas/teclas antes de que el entry las
    // use para mover el cursor, y así las flechas navegan el grid.
    let key_controller = EventControllerKey::new();
    key_controller.connect_key_pressed(clone!(
        #[strong]
        grid,
        #[strong]
        window,
        #[strong]
        sel_idx,
        #[strong]
        entry,
        #[strong]
        run_selected,
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
            let apply_sel = |new_idx: i32| {
                if new_idx < 0 {
                    *sel_idx.borrow_mut() = new_idx;
                    return;
                }
                *sel_idx.borrow_mut() = new_idx;
                let children = grid.observe_children();
                for i in 0..children.n_items() {
                    if let Some(obj) = children.item(i) {
                        if let Ok(w) = obj.downcast::<gtk4::Widget>() {
                            if i as i32 == new_idx {
                                w.add_css_class("selected");
                            } else {
                                w.remove_css_class("selected");
                            }
                        }
                    }
                }
            };

            match key {
                Key::Escape => {
                    window.close();
                    glib::Propagation::Stop
                }
                Key::Down => {
                    apply_sel(move_selection(*sel_idx.borrow(), COLS as i32, total()));
                    glib::Propagation::Stop
                }
                Key::Up => {
                    apply_sel(move_selection(*sel_idx.borrow(), -(COLS as i32), total()));
                    glib::Propagation::Stop
                }
                Key::Right => {
                    apply_sel(move_selection(*sel_idx.borrow(), 1, total()));
                    glib::Propagation::Stop
                }
                Key::Left => {
                    apply_sel(move_selection(*sel_idx.borrow(), -1, total()));
                    glib::Propagation::Stop
                }
                Key::Return | Key::KP_Enter => {
                    run_selected();
                    glib::Propagation::Stop
                }
                Key::BackSpace => {
                    let text = entry.text().to_string();
                    entry.set_text(&apply_backspace(&text));
                    entry.set_position(-1);
                    glib::Propagation::Stop
                }
                _ => {
                    // Teclas imprimibles: escribir en la barra y filtrar.
                    if let Some(c) = key.to_unicode() {
                        if !c.is_control() {
                            let text = entry.text().to_string();
                            entry.set_text(&apply_char(&text, c));
                            entry.set_position(-1);
                        }
                        glib::Propagation::Stop
                    } else {
                        glib::Propagation::Proceed
                    }
                }
            }
        },
    ));
    key_controller.set_propagation_phase(gtk4::PropagationPhase::Capture);
    entry.add_controller(key_controller);

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
             border-radius: 14px;
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
    // Provider global (display) para que aplique a TODOS los widgets,
    // incluido el banner-box (el provider de la ventana no alcanzaba).
    gtk4::style_context_add_provider_for_display(
        &gtk4::prelude::WidgetExt::display(&window),
        &css,
        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    // El launcher se opera 100% con teclado: el entry intercepta las teclas
    // en fase captura (flechas navegan, letras escriben, Enter ejecuta).
    window.present();
    entry.grab_focus();
}

fn main() {
    let app = Application::builder().application_id("dev.loonbac.loonlaunch").build();
    app.connect_activate(build_ui);
    app.run();
}

// ---------- Tests ----------
#[cfg(test)]
mod tests {
    use super::*;

    fn app(name: &str) -> Item {
        Item { name: name.to_string(), exec: "true".to_string(), icon: "x".to_string() }
    }

    fn power() -> Vec<Item> {
        power_actions()
    }

    #[test]
    fn filter_matches_by_name_case_insensitive() {
        let apps = vec![app("Firefox"), app("Ghostty"), app("VS Code")];
        let got = filter_items(&apps, &power(), "fire");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].name, "Firefox");
    }

    #[test]
    fn filter_empty_query_returns_all() {
        let apps = vec![app("A"), app("B")];
        let got = filter_items(&apps, &power(), "");
        assert_eq!(got.len(), 2);
    }

    #[test]
    fn filter_power_mode_prefix() {
        let apps = vec![app("Firefox")];
        let got = filter_items(&apps, &power(), ">apag");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].name, "Apagar");
    }

    #[test]
    fn filter_power_empty_shows_all_power() {
        let got = filter_items(&[], &power(), ">");
        assert_eq!(got.len(), power().len());
    }

    #[test]
    fn move_sel_right_steps_one() {
        assert_eq!(move_selection(0, 1, 10), 1);
        assert_eq!(move_selection(9, 1, 10), 9); // clampa al final
    }

    #[test]
    fn move_sel_left_clamps_at_zero() {
        assert_eq!(move_selection(0, -1, 10), 0);
        assert_eq!(move_selection(1, -1, 10), 0);
    }

    #[test]
    fn move_sel_down_steps_cols() {
        assert_eq!(move_selection(0, COLS as i32, 20), COLS as i32);
        assert_eq!(move_selection(18, COLS as i32, 20), 19); // clampa
    }

    #[test]
    fn move_sel_empty_returns_neg1() {
        assert_eq!(move_selection(0, 1, 0), -1);
    }

    #[test]
    fn move_sel_from_invalid_anchors_to_zero() {
        // sel inválido (-1) se ancla a 0 (primera celda).
        assert_eq!(move_selection(-1, 1, 10), 0);
        assert_eq!(move_selection(-1, -1, 10), 0);
    }

    #[test]
    fn normalize_sel_resets_out_of_range() {
        assert_eq!(normalize_selection(5, 3), 0);
        assert_eq!(normalize_selection(-2, 3), 0);
        assert_eq!(normalize_selection(2, 3), 2);
        assert_eq!(normalize_selection(0, 0), -1);
    }

    #[test]
    fn char_and_backspace_edit_text() {
        assert_eq!(apply_char("gh", 'o'), "gho");
        assert_eq!(apply_backspace("gho"), "gh");
        assert_eq!(apply_backspace(""), "");
    }
}
