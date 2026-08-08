// Modelos IPC de niri (JSON de `niri msg --json`).
// `workspace_id` en windows puede ser None si la ventana no está
// asociada a un workspace (p. ej. layer-shell).
use serde::Deserialize;

#[derive(Deserialize, Debug, Clone)]
pub struct NiriWindow {
    pub id: u64,
    pub title: Option<String>,
    pub app_id: Option<String>,
    pub workspace_id: Option<u64>,
    pub is_focused: bool,
}

#[derive(Deserialize, Debug)]
pub struct NiriWorkspace {
    pub id: u64,
    pub idx: u64,
    pub is_active: bool,
}

/// Grupo de ventanas que comparten (app_id, workspace).
/// Un botón por grupo en la taskbar.
#[derive(Debug, Clone)]
pub struct AppGroup {
    pub app_id: String,
    pub display_name: String,
    // Índice del workspace (1, 2, 3...) para ordenar de izquierda a derecha.
    pub workspace_idx: u64,
    pub windows: Vec<NiriWindow>,
}
