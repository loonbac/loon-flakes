// Acciones al hacer click en un grupo de la taskbar (estilo Windows 10):
//   - Grupo con ventana enfocada  -> ciclar a la siguiente ventana
//     del grupo (mismo app_id y workspace).
//   - Grupo sin foco, con ventana en el ws activo -> enfocar esa.
//   - Grupo sin foco, sin ventana en el ws activo -> cambiar de
//     workspace y enfocar la primera.
//
// Nota: estas acciones se disparan desde el hilo de GTK, así que leen
// el snapshot compartido (sin I/O de socket) y solo lanzan `niri msg`
// como procesos externos (no bloquean el render).
use std::process::Command;

use crate::models::AppGroup;
use crate::niri::current_snapshot;

pub fn activate_group(group: &AppGroup) {
    let (_, _windows, workspaces) = current_snapshot();
    let active_ws = workspaces.iter().find(|w| w.is_active).map(|w| w.id);
    let focused = group.windows.iter().find(|w| w.is_focused);
    let first = group.windows.first().cloned();

    let target = if focused.is_some() {
        // Ciclar: siguiente ventana del grupo (por orden de id).
        let idx = group
            .windows
            .iter()
            .position(|w| w.is_focused)
            .unwrap_or(0);
        group.windows[(idx + 1) % group.windows.len()].clone()
    } else if let Some(ws) = active_ws {
        // Preferir una ventana del grupo que esté en el workspace activo.
        group
            .windows
            .iter()
            .find(|w| w.workspace_id == Some(ws))
            .cloned()
            .unwrap_or_else(|| first.unwrap())
    } else {
        first.unwrap()
    };

    // Si la ventana está en otro workspace, primero cambia de workspace.
    // OJO: `focus-workspace` usa referencia por índice (no --id).
    if let Some(ws_id) = target.workspace_id {
        if active_ws != Some(ws_id) {
            // Buscar el idx del workspace destino para enfocarlo.
            if let Some(idx) = workspaces.iter().find(|w| w.id == ws_id).map(|w| w.idx) {
                let _ = Command::new("niri")
                    .args(["msg", "action", "focus-workspace", &idx.to_string()])
                    .spawn();
            }
        }
    }
    let _ = Command::new("niri")
        .args(["msg", "action", "focus-window", "--id", &target.id.to_string()])
        .spawn();
}
