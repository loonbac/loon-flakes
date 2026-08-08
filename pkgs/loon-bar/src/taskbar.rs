// Barra de tareas: renderizado de botones por grupo (app_id, workspace)
// y refresco en tiempo real. Reutiliza las claves `btn:{ws}:{app_id}`
// para reconstruir solo cuando cambia el conjunto de apps.
//
// IMPORTANTE: los botones NO se recrean en cada tick. Recrear widgets
// cada 100ms rompe el render de GTK (el texto deja de dibujarse). Solo
// se reconstruyen cuando cambia el conjunto de apps (abrir/cerrar
// ventana); en los refrescos de foco solo se actualiza la clase "active".
//
// Este módulo NO toca el socket de niri: lee el snapshot publicado por
// el hilo poller (niri.rs). El render nunca se bloquea.
use gtk4::prelude::*;

use crate::actions::activate_group;
use crate::grouping::{get_app_icon_glyph, group_windows};
use crate::niri::current_snapshot;

/// Refresca la barra de tareas dentro del contenedor dado.
/// Llamar en el tick del loop principal (cada ~100ms).
/// Devuelve true si el snapshot cambió en este tick.
pub fn refresh_taskbar(taskbar_group: &gtk4::Box) -> bool {
    let (_seq, windows, workspaces) = current_snapshot();
    let groups = group_windows(windows, &workspaces);

    // Claves actuales: (app_id, workspace_idx) en orden.
    let keys: Vec<(String, u64)> = groups
        .iter()
        .map(|g| (g.app_id.clone(), g.workspace_idx))
        .collect();

    // Estado anterior: las claves que ya tienen botón.
    let mut existing: Vec<(String, u64)> = Vec::new();
    let mut child = taskbar_group.first_child();
    while let Some(widget) = child {
        if let Some(name) = widget.widget_name().to_string().strip_prefix("btn:") {
            let parts: Vec<&str> = name.splitn(2, ':').collect();
            let ws: u64 = parts[0].parse().unwrap_or(0);
            existing.push((parts[1].to_string(), ws));
        }
        child = widget.next_sibling();
    }

    // Si el conjunto de apps cambió, reconstruir toda la barra.
    if existing != keys {
        // Limpiar hijos anteriores
        while let Some(child) = taskbar_group.first_child() {
            taskbar_group.remove(&child);
        }

        if !groups.is_empty() {
            taskbar_group.set_visible(true);

            // Agrupar visualmente por workspace: las apps del mismo
            // workspace van contiguas, con un separador entre workspaces.
            let mut last_ws_idx: Option<u64> = None;
            for group in &groups {
                if last_ws_idx != Some(group.workspace_idx) {
                    if last_ws_idx.is_some() {
                        // Separador entre workspaces (Label "│": fiable
                        // de renderizar, a diferencia de Separator/Box).
                        let sep = gtk4::Label::new(Some("│"));
                        sep.set_widget_name("ws-sep");
                        sep.add_css_class("ws-sep");
                        taskbar_group.append(&sep);
                    }
                    last_ws_idx = Some(group.workspace_idx);
                }

                let icon = get_app_icon_glyph(&group.app_id);
                let count = group.windows.len();

                // Label del botón: ícono + nombre (+ badge ×N en el texto).
                // Se usa Label + GestureClick (NO Button): el texto de los
                // Button no se renderiza con este CSS/tema; los Label sí.
                let mut label = format!("{} {}", icon, group.display_name);
                if count > 1 {
                    label.push_str(&format!("  ×{}", count));
                }
                let btn = gtk4::Label::new(Some(&label));
                btn.add_css_class("taskbar-item");
                btn.set_valign(gtk4::Align::Center);
                // Widget name para detectar cambios del conjunto de apps.
                let btn_name = format!("btn:{}:{}", group.workspace_idx, group.app_id);
                btn.set_widget_name(&btn_name);
                btn.set_selectable(false);

                // Tooltip con los títulos de todas las ventanas del grupo
                let tooltip = group
                    .windows
                    .iter()
                    .filter_map(|w| w.title.clone())
                    .collect::<Vec<_>>()
                    .join("\n");
                btn.set_tooltip_text(Some(&tooltip));

                // Indicador activo: el grupo tiene la ventana enfocada
                if group.windows.iter().any(|w| w.is_focused) {
                    btn.add_css_class("active");
                }

                // Click (gesto) para activar el grupo.
                let group_clone = group.clone();
                let gesture = gtk4::GestureClick::new();
                gesture.connect_released(move |_, _, _, _| {
                    activate_group(&group_clone);
                });
                btn.add_controller(gesture);

                taskbar_group.append(&btn);
            }
        }
        if groups.is_empty() {
            taskbar_group.set_visible(false);
        }
    } else {
        // El conjunto de apps no cambió: solo actualizar la clase
        // "active" de cada botón (cambio de foco / workspace).
        let focused: Vec<(String, u64)> = groups
            .iter()
            .filter(|g| g.windows.iter().any(|w| w.is_focused))
            .map(|g| (g.app_id.clone(), g.workspace_idx))
            .collect();

        let mut child = taskbar_group.first_child();
        while let Some(widget) = child {
            if let Some(name) = widget.widget_name().to_string().strip_prefix("btn:") {
                let parts: Vec<&str> = name.splitn(2, ':').collect();
                let ws: u64 = parts[0].parse().unwrap_or(0);
                let key = (parts[1].to_string(), ws);
                let is_active = focused.contains(&key);
                if is_active {
                    widget.add_css_class("active");
                } else {
                    widget.remove_css_class("active");
                }
                // Forzar que GTK re-aplique el estilo tras cambiar la
                // clase (sin esto, el fondo azul no se repinta).
                widget.queue_resize();
                widget.queue_draw();
            }
            child = widget.next_sibling();
        }
    }
    true
}
