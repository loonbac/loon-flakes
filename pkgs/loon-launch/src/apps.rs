// Carga de aplicaciones desde .desktop files y acciones de poder.
use std::fs;
use std::path::Path;

use crate::models::Item;

pub fn load_apps() -> Vec<Item> {
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

    apps.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| b.exec.contains("waydroid-app").cmp(&a.exec.contains("waydroid-app")))
    });
    apps.dedup_by(|a, b| a.name.to_lowercase() == b.name.to_lowercase());
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

    Some(Item::app(name, exec, icon))
}

pub fn power_actions() -> Vec<Item> {
    vec![
        Item::app("Cambiar fondo de pantalla", "wallpaper-mode", "preferences-desktop-wallpaper"),
        Item::app("Apagar", "systemctl poweroff", "system-shutdown"),
        Item::app("Reiniciar", "systemctl reboot", "system-reboot"),
        Item::app("Hibernar", "systemctl hibernate", "system-suspend-hibernate"),
        Item::app("Suspender", "systemctl suspend", "system-suspend"),
        Item::app("Bloquear", "loginctl lock-session", "system-lock-screen"),
    ]
}
