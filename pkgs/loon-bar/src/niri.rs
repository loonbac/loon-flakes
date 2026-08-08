// IPC directo con niri: conexión al socket UNIX ($NIRI_SOCKET),
// request en JSON en una sola línea + newline, respuesta JSON.
// Más rápido y robusto que spawnear `niri msg` por consulta.
//
// El acceso al socket se hace SIEMPRE desde un hilo de fondo (ver
// `spawn_niri_poller`). El hilo principal de GTK solo lee el snapshot
// más reciente (atómico, sin bloqueo), así que la UI nunca se congela
// aunque niri tarde en responder o el socket se atasque.
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::models::{NiriWindow, NiriWorkspace};

// ---------------------------------------------------------------
// Snapshot compartido: el poller escribe, la UI lee.
// ---------------------------------------------------------------

/// Snapshot atómico del estado de niri visto por el poller.
/// `seq` se incrementa con cada escritura; la UI lo usa para detectar
/// cambios sin necesidad de locks prolongados.
#[derive(Default)]
pub struct NiriSnapshot {
    pub seq: AtomicU64,
    pub windows: Mutex<Vec<NiriWindow>>,
    pub workspaces: Mutex<Vec<NiriWorkspace>>,
}

/// Handler global del snapshot (inicializado por `spawn_niri_poller`).
static SNAPSHOT: std::sync::OnceLock<Arc<NiriSnapshot>> = std::sync::OnceLock::new();

fn snapshot() -> &'static Arc<NiriSnapshot> {
    SNAPSHOT.get_or_init(|| Arc::new(NiriSnapshot::default()))
}

/// Crea el snapshot y lanza el hilo que hace polling del socket de niri.
pub fn spawn_niri_poller() {
    let snap = snapshot().clone();

    std::thread::Builder::new()
        .name("niri-poller".into())
        .spawn(move || loop {
            // Un fetch completo de windows + workspaces.
            let windows = fetch_windows_io();
            let workspaces = fetch_workspaces_io();

            // Publicar el snapshot en un solo paso (atómico para la UI).
            {
                let mut w = snap.windows.lock().unwrap();
                *w = windows;
                let mut ws = snap.workspaces.lock().unwrap();
                *ws = workspaces;
            }
            snap.seq.fetch_add(1, Ordering::Release);

            // Rate-limit: no martillar el socket más de cada 50ms.
            std::thread::sleep(Duration::from_millis(50));
        });
}

/// Snapshot actual visto por la UI: (seq, windows, workspaces).
/// Devuelve las ventanas ya filtradas (sin apps internas de loon).
pub fn current_snapshot() -> (u64, Vec<NiriWindow>, Vec<NiriWorkspace>) {
    let snap = snapshot();
    let seq = snap.seq.load(Ordering::Acquire);
    let windows = snap.windows.lock().unwrap().clone();
    let workspaces = snap.workspaces.lock().unwrap().clone();
    (seq, windows, workspaces)
}

// ---------------------------------------------------------------
// I/O puro del socket (solo lo usa el hilo poller).
// ---------------------------------------------------------------

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

fn fetch_windows_io() -> Vec<NiriWindow> {
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

fn fetch_workspaces_io() -> Vec<NiriWorkspace> {
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
