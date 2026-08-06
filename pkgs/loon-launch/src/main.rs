use glib::clone;
use gtk4::gdk::Key;
use gtk4::prelude::*;
use gtk4::{
    Application, ApplicationWindow, Entry, EventControllerKey, ListBox, ListBoxRow,
    Orientation, SelectionMode,
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

// ---------- Acciones de poder (modo ">") ----------
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
        .default_width(720)
        .default_height(480)
        .decorated(false)
        .build();

    let vbox = gtk4::Box::new(Orientation::Vertical, 0);
    window.set_child(Some(&vbox));

    let entry = Entry::new();
    entry.set_placeholder_text(Some("Buscar app… (escribe '>' para acciones de poder)"));
    entry.set_margin_bottom(8);
    entry.set_margin_top(12);
    entry.set_margin_start(12);
    entry.set_margin_end(12);
    vbox.append(&entry);

    let list = ListBox::new();
    list.set_activate_on_single_click(false);
    list.set_selection_mode(SelectionMode::Single);
    list.set_show_separators(false);
    vbox.append(&list);

    let scrolled = gtk4::ScrolledWindow::builder().child(&list).hexpand(true).vexpand(true).build();
    vbox.append(&scrolled);

    let all_apps = load_apps();
    let power = power_actions();

    fn repopulate(
        list: &ListBox,
        all_apps: &[Item],
        power: &[Item],
        query: &str,
    ) -> Vec<Item> {
        while let Some(row) = list.first_child() {
            list.remove(&row);
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

        for (i, item) in shown.iter().enumerate() {
            let row = ListBoxRow::new();
            let label = gtk4::Label::new(Some(&item.name));
            label.set_xalign(0.0);
            label.set_margin_top(8);
            label.set_margin_bottom(8);
            label.set_margin_start(12);
            label.set_margin_end(12);
            row.set_child(Some(&label));
            list.append(&row);
            // Seleccionar la primera fila por defecto (100% teclado).
            if i == 0 {
                list.select_row(Some(&row));
            }
        }

        shown
    }

    let current_items = Rc::new(RefCell::new(repopulate(&list, &all_apps, &power, "")));

    entry.connect_changed(clone!(
        #[strong]
        list,
        #[strong]
        entry,
        #[strong]
        all_apps,
        #[strong]
        power,
        #[strong]
        current_items,
        move |_| {
            let q = entry.text().to_string();
            *current_items.borrow_mut() = repopulate(&list, &all_apps, &power, &q);
        },
    ));

    let run_selected = clone!(
        #[strong]
        list,
        #[strong]
        window,
        #[strong]
        current_items,
        move || {
            if let Some(row) = list.selected_row() {
                let idx = row.index() as usize;
                let items = current_items.borrow();
                if idx < items.len() {
                    let item = &items[idx];
                    // Ejecutar el comando de forma independiente.
                    let exec = item.exec.clone();
                    std::thread::spawn(move || {
                        let _ = std::process::Command::new("sh").arg("-c").arg(&exec).spawn();
                    });
                }
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
        list,
        #[strong]
        window,
        #[strong]
        run_selected,
        move |_, key, _, _| {
            match key {
                Key::Escape => {
                    window.close();
                    glib::Propagation::Stop
                }
                Key::Down => {
                    if let Some(row) = list.selected_row() {
                        if let Some(next) = row.next_sibling() {
                            if let Some(next_row) = next.downcast::<ListBoxRow>().ok() {
                                list.select_row(Some(&next_row));
                            }
                        }
                    } else if let Some(first) = list.first_child() {
                        if let Some(first_row) = first.downcast::<ListBoxRow>().ok() {
                            list.select_row(Some(&first_row));
                        }
                    }
                    glib::Propagation::Stop
                }
                Key::Up => {
                    if let Some(row) = list.selected_row() {
                        if let Some(prev) = row.prev_sibling() {
                            if let Some(prev_row) = prev.downcast::<ListBoxRow>().ok() {
                                list.select_row(Some(&prev_row));
                            }
                        }
                    }
                    glib::Propagation::Stop
                }
                _ => glib::Propagation::Proceed,
            }
        },
    ));
    entry.add_controller(key_controller);

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
