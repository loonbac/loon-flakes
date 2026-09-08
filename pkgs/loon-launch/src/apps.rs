// Carga de aplicaciones desde .desktop files y acciones de poder.
use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::models::Item;

pub fn load_apps() -> Vec<Item> {
    let mut apps = Vec::new();

    for dir in application_dirs() {
        if !dir.is_dir() {
            continue;
        }
        if let Ok(entries) = fs::read_dir(&dir) {
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

/// Raíces XDG que pueden exportar aplicaciones e iconos. Las rutas de
/// Flatpak se agregan explícitamente porque una instalación puede aparecer
/// mientras el daemon sigue usando el entorno de una sesión ya iniciada.
pub fn data_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    let mut seen = HashSet::new();

    let data_home = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));

    if let Some(ref dir) = data_home {
        push_unique(&mut dirs, &mut seen, dir.clone());
        push_unique(&mut dirs, &mut seen, dir.join("flatpak/exports/share"));
    }

    if let Some(value) = env::var_os("XDG_DATA_DIRS") {
        for dir in env::split_paths(&value) {
            push_unique(&mut dirs, &mut seen, dir);
        }
    } else {
        push_unique(&mut dirs, &mut seen, PathBuf::from("/usr/local/share"));
        push_unique(&mut dirs, &mut seen, PathBuf::from("/usr/share"));
    }

    // Fallbacks de NixOS y Flatpak. Se consultan en cada apertura, así una
    // app recién instalada aparece aunque estas rutas no estuvieran en el
    // XDG_DATA_DIRS heredado al iniciar la sesión.
    push_unique(
        &mut dirs,
        &mut seen,
        PathBuf::from("/run/current-system/sw/share"),
    );
    push_unique(
        &mut dirs,
        &mut seen,
        PathBuf::from("/var/lib/flatpak/exports/share"),
    );

    dirs
}

fn application_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    let mut seen = HashSet::new();

    for data_dir in data_dirs() {
        let applications = data_dir.join("applications");
        push_unique(&mut dirs, &mut seen, applications.clone());
        push_unique(&mut dirs, &mut seen, applications.join("kde"));
    }

    dirs
}

fn push_unique(dirs: &mut Vec<PathBuf>, seen: &mut HashSet<PathBuf>, dir: PathBuf) {
    if seen.insert(dir.clone()) {
        dirs.push(dir);
    }
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
