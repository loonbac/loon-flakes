// Agrupación de ventanas en grupos (app_id, workspace) y helpers de
// nombre/ícono para la taskbar.
//
// Orden de izquierda a derecha:
//   1. Por índice de workspace (1, 2, 3...) — la app abierta en el
//      workspace 1 va primero, luego las del 2, etc.
//   2. Dentro del mismo workspace, por orden de apertura (el JSON de
//      `niri msg windows` ya viene ordenado por posición en el
//      workspace, que es el orden de creación).
//   3. Ventanas sin workspace (workspace_id None) van al final.
use std::collections::HashMap;

use crate::models::{AppGroup, NiriWindow, NiriWorkspace};

/// Agrupa ventanas por (app_id, workspace).
///
/// Dos ventanas del mismo app_id en workspaces DISTINTOS no se agrupan:
/// cada una tiene su propio botón. Solo se agrupan las del mismo app_id
/// DENTRO del mismo workspace (con badge ×N estilo Windows 10).
pub fn group_windows(windows: Vec<NiriWindow>, workspaces: &[NiriWorkspace]) -> Vec<AppGroup> {
    // Mapa workspace_id -> idx (para ordenar).
    let ws_idx: HashMap<u64, u64> = workspaces.iter().map(|w| (w.id, w.idx)).collect();

    let mut groups: Vec<AppGroup> = Vec::new();
    for win in windows {
        let app_id = win.app_id.clone().unwrap_or_else(|| "unknown".to_string());

        // Posición de orden del workspace de esta ventana.
        let ws_pos = win
            .workspace_id
            .and_then(|wid| ws_idx.get(&wid).copied())
            .unwrap_or(u64::MAX); // sin workspace -> al final

        if let Some(g) = groups
            .iter_mut()
            .find(|g| g.app_id == app_id && g.workspace_idx == ws_pos)
        {
            g.windows.push(win.clone());
        } else {
            groups.push(AppGroup {
                display_name: format_app_name(win.title.as_deref(), Some(&app_id)),
                app_id: app_id.clone(),
                workspace_idx: ws_pos,
                windows: vec![win],
            });
        }
    }

    // Orden: workspace_idx asc; empate -> mantener el orden de aparición
    // (sort_by es estable).
    groups.sort_by_key(|g| g.workspace_idx);
    groups
}

/// Ícono Nerd Font por app_id.
pub fn get_app_icon_glyph(app_id: &str) -> &'static str {
    match app_id.to_lowercase().as_str() {
        s if s.contains("ghostty") || s.contains("terminal") => "",
        s if s.contains("zen") || s.contains("firefox") || s.contains("browser") => "󰈹",
        s if s.contains("code") => "󰨞",
        s if s.contains("equibop") || s.contains("discord") => "󰙯",
        s if s.contains("vlc") => "󰕼",
        s if s.contains("files") || s.contains("nautilus") || s.contains("thunar") => "󰉋",
        _ => "󰣆",
    }
}

/// Nombre mostrable (estilo Windows 10) a partir del app_id o título.
pub fn format_app_name(title: Option<&str>, app_id: Option<&str>) -> String {
    let name = app_id.or(title).unwrap_or("App");

    match name.to_lowercase().as_str() {
        s if s.contains("ghostty") => "Ghostty".to_string(),
        s if s.contains("zen") => "Zen Browser".to_string(),
        s if s.contains("firefox") => "Firefox".to_string(),
        s if s.contains("code") => "VS Code".to_string(),
        s if s.contains("equibop") => "Equibop".to_string(),
        _ => {
            let t = title.unwrap_or(name);
            if t.len() > 20 {
                format!("{}...", &t[..17])
            } else {
                t.to_string()
            }
        }
    }
}
