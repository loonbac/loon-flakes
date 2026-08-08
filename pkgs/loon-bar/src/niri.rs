// IPC directo con niri: conexión al socket UNIX ($NIRI_SOCKET),
// request en JSON en una sola línea + newline, respuesta JSON.
// Más rápido y robusto que spawnear `niri msg` por consulta.
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use crate::models::{NiriWindow, NiriWorkspace};

fn niri_socket_path() -> Option<std::path::PathBuf> {
    std::env::var_os("NIRI_SOCKET")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            // Fallback: buscar el socket en el runtime dir.
            let dir = std::env::var_os("XDG_RUNTIME_DIR")?;
            let dir = std::path::PathBuf::from(dir);
            std::fs::read_dir(&dir)
                .ok()?
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .find(|p| {
                    p.file_name()
                        .map(|n| n.to_string_lossy().starts_with("niri."))
                        .unwrap_or(false)
                })
        })
}

/// Envía un request JSON al socket de niri y devuelve la primera línea
/// de respuesta (un objeto JSON `{"Ok": ...}` o `{"Err": ...}`).
fn niri_request(request: &str) -> Option<Value> {
    let path = niri_socket_path()?;
    let mut stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(1))).ok()?;
    stream.write_all(request.as_bytes()).ok()?;
    stream.write_all(b"\n").ok()?;
    stream.flush().ok()?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

/// ¿Es una app interna de loon (barra o launcher)? Se excluyen de la taskbar.
fn is_loon_internal(app_id: &str) -> bool {
    let lower = app_id.to_lowercase();
    lower == "loon-launch"
        || lower == "loon-bar"
        || lower.contains("loonbar")
        || lower == "dev.loonbac.loonlaunch"
        || lower.contains("loonlaunch")
}

pub fn fetch_windows() -> Vec<NiriWindow> {
    let windows: Vec<NiriWindow> = match niri_request(r#""Windows""#) {
        Some(Value::Object(mut obj)) => obj
            .remove("Ok")
            .and_then(|v| v.as_object().cloned())
            .and_then(|mut o| o.remove("Windows"))
            .and_then(|v| serde_json::from_value(v).ok()),
        _ => None,
    }
    .unwrap_or_default();

    windows
        .into_iter()
        .filter(|w| !w.app_id.as_deref().map(is_loon_internal).unwrap_or(false))
        .collect()
}

pub fn fetch_workspaces() -> Vec<NiriWorkspace> {
    match niri_request(r#""Workspaces""#) {
        Some(Value::Object(mut obj)) => obj
            .remove("Ok")
            .and_then(|v| v.as_object().cloned())
            .and_then(|mut o| o.remove("Workspaces"))
            .and_then(|v| serde_json::from_value(v).ok()),
        _ => None,
    }
    .unwrap_or_default()
}

pub fn fetch_active_workspace_id() -> Option<u64> {
    fetch_workspaces()
        .into_iter()
        .find(|w| w.is_active)
        .map(|w| w.id)
}
