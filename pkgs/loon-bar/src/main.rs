use gtk4::gdk;
use gtk4::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use serde::Deserialize;
use serde_json::Value;
use std::cell::{Cell, RefCell};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::Command;
use std::rc::Rc;
use std::time::Duration;

// ---------------------------------------------------------------
// Modelos IPC de niri (JSON de `niri msg --json`).
// `workspace_id` en windows puede ser None si la ventana no está
// asociada a un workspace (p. ej. layer-shell).
// ---------------------------------------------------------------
#[derive(Deserialize, Debug, Clone)]
struct NiriWindow {
    id: u64,
    title: Option<String>,
    app_id: Option<String>,
    workspace_id: Option<u64>,
    is_focused: bool,
}

#[derive(Deserialize, Debug)]
struct NiriWorkspace {
    id: u64,
    idx: u64,
    is_active: bool,
}

#[derive(Debug, Clone)]
struct AppGroup {
    app_id: String,
    display_name: String,
    // Índice del workspace (1, 2, 3...) para ordenar de izquierda a derecha.
    workspace_idx: u64,
    windows: Vec<NiriWindow>,
}

// ---------------------------------------------------------------
// IPC directo con niri: conexión al socket UNIX ($NIRI_SOCKET),
// request en JSON en una sola línea + newline, respuesta JSON.
// Más rápido y robusto que spawnear `niri msg` por consulta.
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

fn fetch_windows() -> Vec<NiriWindow> {
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
        .filter(|w| {
            if let Some(ref app) = w.app_id {
                // Excluir la propia barra y el launcher (loon-launch usa
                // app_id "dev.loonbac.loonlaunch", no "loon-launch").
                let lower = app.to_lowercase();
                if lower == "loon-launch"
                    || lower == "loon-bar"
                    || lower.contains("loonbar")
                    || lower == "dev.loonbac.loonlaunch"
                    || lower.contains("loonlaunch")
                {
                    return false;
                }
            }
            true
        })
        .collect()
}

fn fetch_workspaces() -> Vec<NiriWorkspace> {
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

fn fetch_active_workspace_id() -> Option<u64> {
    fetch_workspaces().into_iter().find(|w| w.is_active).map(|w| w.id)
}

// ---------------------------------------------------------------
// Agrupación estilo Windows 10: un botón por app_id, con TODAS las
// ventanas de todos los workspaces.
//
// Orden de izquierda a derecha:
//   1. Por índice de workspace (1, 2, 3...) — la app abierta en el
//      workspace 1 va primero, luego las del 2, etc.
//   2. Dentro del mismo workspace, por orden de apertura (el JSON de
//      `niri msg windows` ya viene ordenado por posición en el
//      workspace, que es el orden de creación).
//   3. Ventanas sin workspace (workspace_id None) van al final.
// ---------------------------------------------------------------
fn group_windows(windows: Vec<NiriWindow>, workspaces: &[NiriWorkspace]) -> Vec<AppGroup> {
    // Mapa workspace_id -> idx (para ordenar).
    let ws_idx: std::collections::HashMap<u64, u64> = workspaces
        .iter()
        .map(|w| (w.id, w.idx))
        .collect();

    let mut groups: Vec<AppGroup> = Vec::new();
    for win in windows {
        let app_id = win.app_id.clone().unwrap_or_else(|| "unknown".to_string());

        // Posición de orden del workspace de esta ventana.
        let ws_pos = win
            .workspace_id
            .and_then(|wid| ws_idx.get(&wid).copied())
            .unwrap_or(u64::MAX); // sin workspace -> al final

        if let Some(g) = groups.iter_mut().find(|g| g.app_id == app_id) {
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

// ---------------------------------------------------------------
// Ícono Nerd Font por app_id y nombre mostrable.
// ---------------------------------------------------------------
fn get_app_icon_glyph(app_id: &str) -> &'static str {
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

fn format_app_name(title: Option<&str>, app_id: Option<&str>) -> String {
    let name = app_id
        .or(title)
        .unwrap_or("App");

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

// ---------------------------------------------------------------
// Acciones al hacer click (estilo Windows 10):
//   - Grupo con ventana enfocada  -> ciclar a la siguiente ventana.
//   - Grupo sin foco, con ventana en el ws activo -> enfocar esa.
//   - Grupo sin foco, sin ventana en el ws activo -> cambiar de
//     workspace y enfocar la primera.
// ---------------------------------------------------------------
fn activate_group(group: &AppGroup) {
    let active_ws = fetch_active_workspace_id();
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
            if let Some(idx) = fetch_workspaces()
                .into_iter()
                .find(|w| w.id == ws_id)
                .map(|w| w.idx)
            {
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

// ---------------------------------------------------------------
// Utilidades de red (nmcli), audio (wpctl) y batería (sysfs).
// ---------------------------------------------------------------

/// Ejecuta nmcli y devuelve stdout como String (o error).
fn nmcli(args: &[&str]) -> Result<String, String> {
    let out = Command::new("nmcli")
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).to_string())
    }
}

/// ¿Está el radio WiFi activado?
fn wifi_enabled() -> bool {
    nmcli(&["radio", "wifi"])
        .map(|s| s.trim() == "enabled")
        .unwrap_or(false)
}

/// Red WiFi: ssid, señal (%), seguridad (WPA2, Abierta...), conectada.
#[derive(Debug, Clone)]
struct WifiNet {
    ssid: String,
    signal: u32,
    security: String,
    connected: bool,
}

/// Lista las redes WiFi visibles (nmcli -t -e yes -f SSID,SIGNAL,SECURITY,ACTIVE).
fn wifi_list() -> Vec<WifiNet> {
    let out = match nmcli(&["-t", "-e", "yes", "-f", "SSID,SIGNAL,SECURITY,ACTIVE", "dev", "wifi", "list"]) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    let mut nets = Vec::new();
    for line in out.lines() {
        // Formato: SSID:SIGNAL:SECURITY:ACTIVE  (SSID puede contener ':' escapado como '\:')
        let mut parts = line.splitn(4, ':');
        let ssid = parts.next().unwrap_or("").replace("\\:", ":");
        let signal = parts.next().unwrap_or("0").trim().parse::<u32>().unwrap_or(0);
        let security = parts.next().unwrap_or("").trim().to_string();
        let active_raw = parts.next().unwrap_or("").trim();
        let active = active_raw == "sí" || active_raw == "yes";

        if ssid.is_empty() {
            continue;
        }
        nets.push(WifiNet {
            ssid,
            signal,
            security: if security.is_empty() { "Abierta".to_string() } else { security },
            connected: active,
        });
    }
    nets.sort_by(|a, b| b.signal.cmp(&a.signal));
    nets
}

/// SSID de la red a la que estamos conectados (si hay).
fn wifi_connected_ssid() -> Option<String> {
    wifi_list().into_iter().find(|n| n.connected).map(|n| n.ssid)
}

/// Conecta a una red WiFi; si requiere contraseña y no está guardada, usa password.
fn wifi_connect(ssid: &str, password: Option<&str>) -> Result<(), String> {
    let mut args: Vec<&str> = vec!["dev", "wifi", "connect", ssid];
    if let Some(p) = password {
        args.push("password");
        args.push(p);
    }
    nmcli(&args).map(|_| ())
}

fn wifi_disconnect() {
    let _ = nmcli(&["dev", "disconnect", "wifi"]);
}

/// Estado del volumen: porcentaje y mute.
fn volume_state() -> (u32, bool) {
    let out = Command::new("wpctl")
        .args(["get-volume", "@DEFAULT_AUDIO_SINK@"])
        .output()
        .ok();
    match out {
        Some(o) => {
            let text = String::from_utf8_lossy(&o.stdout);
            let muted = text.contains("[MUTED]");
            let pct = text
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse::<f32>().ok())
                .map(|v| (v * 100.0).round() as u32)
                .unwrap_or(100);
            (pct, muted)
        }
        None => (100, false),
    }
}

fn volume_set(pct: u32) {
    let _ = Command::new("wpctl")
        .args(["set-volume", "@DEFAULT_AUDIO_SINK@", &format!("{:.2}", pct as f32 / 100.0)])
        .spawn();
}

/// Estado de batería: porcentaje y si está cargando.
fn battery_state() -> (u32, bool) {
    let capacity = std::fs::read_to_string("/sys/class/power_supply/BAT0/capacity")
        .ok()
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "100".to_string());
    let status = std::fs::read_to_string("/sys/class/power_supply/BAT0/status")
        .ok()
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    (capacity.parse().unwrap_or(100), status == "Charging")
}

fn battery_icon(cap: u32, charging: bool) -> &'static str {
    if charging {
        ""
    } else {
        match cap {
            80..=100 => "",
            55..=79 => "",
            35..=54 => "",
            15..=34 => "",
            _ => "",
        }
    }
}

fn wifi_icon(signal: u32, connected: bool) -> &'static str {
    if !connected {
        "󰤮"
    } else {
        match signal {
            75..=100 => "󰤨",
            50..=74 => "󰤥",
            25..=49 => "󰤢",
            _ => "󰤟",
        }
    }
}

fn volume_icon(pct: u32, muted: bool) -> &'static str {
    if muted {
        "󰝟"
    } else if pct == 0 {
        "󰕿"
    } else if pct < 50 {
        "󰖀"
    } else {
        "󰕾"
    }
}

// ---------------------------------------------------------------
// Refresco del panel de sistema (redes, volumen, batería).
// ---------------------------------------------------------------

/// Pinta la lista de redes en el ListBox.
fn refresh_wifi_list(
    list: &gtk4::ListBox,
    selected: &Rc<RefCell<Option<WifiNet>>>,
    password_row: &gtk4::Box,
    pass_entry: &gtk4::Entry,
) {
    // Limpiar lista
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }

    if !wifi_enabled() {
        let row = gtk4::Label::new(Some("Wi-Fi apagado"));
        row.set_xalign(0.0);
        row.add_css_class("wifi-net-detail");
        list.append(&row);
        return;
    }

    let nets = wifi_list();
    if nets.is_empty() {
        let row = gtk4::Label::new(Some("Sin redes disponibles"));
        row.set_xalign(0.0);
        row.add_css_class("wifi-net-detail");
        list.append(&row);
        return;
    }

    for net in nets {
        // Fila con nombre + detalle (señal, seguridad) e ícono de candado.
        let row_box = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        row_box.set_hexpand(true);

        let text_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        text_box.set_hexpand(true);
        let name_label = gtk4::Label::new(Some(&net.ssid));
        name_label.set_xalign(0.0);
        name_label.add_css_class("wifi-net-name");
        let detail = format!("{}% · {}", net.signal, net.security);
        let detail_label = gtk4::Label::new(Some(&detail));
        detail_label.set_xalign(0.0);
        detail_label.add_css_class("wifi-net-detail");
        text_box.append(&name_label);
        text_box.append(&detail_label);
        row_box.append(&text_box);

        let lock_icon = if net.security != "Abierta" { "" } else { "󰤨" };
        let sig_icon = gtk4::Label::new(Some(lock_icon));
        sig_icon.add_css_class("wifi-net-detail");
        row_box.append(&sig_icon);

        let list_row = gtk4::ListBoxRow::new();
        list_row.set_child(Some(&row_box));
        list_row.add_css_class("wifi-net");
        if net.connected {
            list_row.add_css_class("connected");
        }

        // Click en la red: seleccionar; si es abierta, conectar directo.
        let net_clone = net.clone();
        let selected = selected.clone();
        let password_row = password_row.clone();
        let pass_entry = pass_entry.clone();
        let gesture = gtk4::GestureClick::new();
        gesture.connect_released(move |_, _, _, _| {
            *selected.borrow_mut() = Some(net_clone.clone());
            if net_clone.security != "Abierta" {
                password_row.set_visible(true);
                pass_entry.grab_focus();
            } else {
                password_row.set_visible(false);
                let _ = wifi_connect(&net_clone.ssid, None);
            }
        });
        list_row.add_controller(gesture);

        list.append(&list_row);
    }
}

/// Refresca el estado del panel: volumen, batería, ícono del botón y switch wifi.
fn refresh_panel_state(
    sys_btn: &gtk4::Label,
    vol_icon: &gtk4::Label,
    vol_slider: &gtk4::Scale,
    dragging: &Rc<Cell<bool>>,
    batt_icon: &gtk4::Label,
    batt_label: &gtk4::Label,
    wifi_switch: &gtk4::Switch,
) {
    // Volumen
    let (vol_pct, muted) = volume_state();
    vol_icon.set_text(volume_icon(vol_pct, muted));
    if !dragging.get() {
        vol_slider.set_value(vol_pct as f64);
    }

    // Batería
    let (cap, charging) = battery_state();
    batt_icon.set_text(battery_icon(cap, charging));
    let batt_text = if charging {
        format!("{}% (Cargando)", cap)
    } else {
        format!("{}%", cap)
    };
    batt_label.set_text(&batt_text);

    // Ícono del botón único en la barra
    let wifi_on = wifi_enabled();
    let connected_ssid = wifi_connected_ssid();
    let sig = wifi_list()
        .first()
        .map(|n| n.signal)
        .unwrap_or(0);
    let wifi_ic = if wifi_on {
        wifi_icon(sig, connected_ssid.is_some())
    } else {
        "󰤮"
    };
    let vol_ic = volume_icon(vol_pct, muted);
    let batt_ic = battery_icon(cap, charging);
    sys_btn.set_text(&format!("{} {} {}", wifi_ic, vol_ic, batt_ic));

    // Switch wifi (set_active no emite state-set, no hay bucle)
    wifi_switch.set_active(wifi_on);
}

/// Lee el color de acento actual (~/.config/mpvpaper/accent.txt, escrito por
/// accent-wallpaper). Fallback: azul Windows 10 clásico.
fn load_accent() -> String {
    let path = std::path::Path::new(
        &std::env::var("HOME").unwrap_or_default(),
    )
    .join(".config/mpvpaper/accent.txt");
    std::fs::read_to_string(&path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| s.starts_with('#') && s.len() == 7)
        .unwrap_or_else(|| "#0078d7".to_string())
}

/// Construye el CSS de la barra con el color de acento actual.
/// Usa @define-color para que el acento se aplique a la underbar de la app
/// activa, el botón "Conectar" y la red WiFi conectada.
fn bar_css(accent: &str) -> String {
    format!(
        r#"
            @define-color accent {accent};
            @define-color accent-hover {accent_hover};
            @define-color accent-alpha {accent_alpha};

            window {{
                background-color: rgba(16, 16, 16, 0.94);
                color: #ffffff;
                font-family: "Segoe UI", "FiraCode Nerd Font", "Symbols Nerd Font", sans-serif;
            }}

            /* Logo de NixOS: solo ícono, sin fondo ni hover (no es botón). */
            #start-btn {{
                color: #ffffff;
                font-size: 20px;
            }}

            /* Contenedor de la taskbar: sin recuadro, botones contiguos. */
            #taskbar-group {{
                margin: 0;
                padding: 0;
            }}

            /* Separador entre workspaces (agrupa visualmente las apps
               de un mismo workspace). */
            #ws-sep {{
                font-size: 18px;
                font-weight: bold;
                color: #ffffff;
                padding: 0 8px;
            }}

            /* Botón de app: estilo Windows 10 exacto.
               Indicador inferior: línea de acento de 3px en la activa
               y línea tenue gris/blanca en inactivas abiertas. */
            .taskbar-item {{
                padding: 0 14px;
                margin: 0 2px;
                background-color: rgba(255, 255, 255, 0.04);
                color: rgba(255, 255, 255, 0.85);
                font-size: 12px;
                border-bottom: 2px solid rgba(255, 255, 255, 0.35); /* underbar inactiva */
                min-height: 40px;
            }}
            .taskbar-item:hover {{
                background-color: rgba(255, 255, 255, 0.10);
                color: #ffffff;
                border-bottom: 2px solid rgba(255, 255, 255, 0.6);
            }}
            /* App activa estilo Windows 10: fondo traslúcido + LÍNEA DE ACENTO abajo */
            .taskbar-item.active {{
                background-color: rgba(255, 255, 255, 0.14);
                color: #ffffff;
                border-bottom: 3px solid @accent;
            }}
            .taskbar-item.active:hover {{
                background-color: rgba(255, 255, 255, 0.20);
                border-bottom: 3px solid @accent-hover;
            }}

            /* System Tray: Íconos a la izquierda de la hora */
            #tray-box {{
                margin-right: 6px;
            }}
            .tray-icon {{
                font-size: 14px;
                padding: 6px 8px;
                color: rgba(255, 255, 255, 0.9);
                border-radius: 2px;
            }}
            .tray-icon:hover {{
                background-color: rgba(255, 255, 255, 0.12);
                color: #ffffff;
            }}

            #clock-label {{
                font-size: 12px;
                font-weight: 600;
                padding: 3px 14px;
            }}
            #clock-label:hover {{
                background-color: rgba(255, 255, 255, 0.12);
            }}

            /* ---- Panel desplegable de sistema (WiFi/Volumen/Batería) ---- */
            #sys-panel {{
                background-color: #1f1f1f;
                color: #ffffff;
                border-radius: 0;
                border-left: 1px solid #333333;
                padding: 16px;
            }}
            #sys-panel-title {{
                font-size: 14px;
                font-weight: 700;
                margin-bottom: 8px;
            }}
            .sys-toggle-row {{
                padding: 4px 0;
            }}
            .sys-toggle-label {{
                font-size: 13px;
                font-weight: 600;
            }}
            .wifi-list {{
                margin-top: 8px;
                margin-bottom: 8px;
            }}
            .wifi-net {{
                padding: 4px 10px;
                border-radius: 4px;
            }}
            .wifi-net:hover {{
                background-color: rgba(255, 255, 255, 0.08);
            }}
            .wifi-net.connected {{
                background-color: @accent-alpha;
            }}
            .wifi-net-name {{
                font-size: 13px;
                font-weight: 500;
            }}
            .wifi-net-detail {{
                font-size: 11px;
                color: rgba(255, 255, 255, 0.6);
            }}
            .wifi-password-entry {{
                margin-top: 6px;
            }}
            .sys-connect-btn {{
                background-color: @accent;
                color: #ffffff;
                border-radius: 4px;
                padding: 6px 14px;
                font-weight: 600;
                font-size: 12px;
                margin-top: 6px;
            }}
            .sys-connect-btn:hover {{
                background-color: @accent-hover;
            }}
            .sys-slider-row {{
                margin-top: 12px;
                margin-bottom: 4px;
            }}
            .sys-slider {{
                min-width: 180px;
            }}
            .sys-status-row {{
                margin-top: 12px;
                font-size: 12px;
                color: rgba(255, 255, 255, 0.75);
            }}
        "#,
        accent = accent,
        accent_hover = accent_hover(accent),
        accent_alpha = accent_alpha(accent),
    )
}

/// Versión más clara del acento para el hover (mezcla con blanco al 50%).
fn accent_hover(hex: &str) -> String {
    let r = u8::from_str_radix(&hex[1..3], 16).unwrap_or(0) as u16;
    let g = u8::from_str_radix(&hex[3..5], 16).unwrap_or(0) as u16;
    let b = u8::from_str_radix(&hex[5..7], 16).unwrap_or(0) as u16;
    let mix = |c: u16| ((c + 255) / 2) as u8;
    format!("#{:02x}{:02x}{:02x}", mix(r), mix(g), mix(b))
}

/// Acento con alpha 25% (para la red WiFi conectada). GTK4 acepta #rrggbbaa.
fn accent_alpha(hex: &str) -> String {
    format!("{}40", hex)
}

fn main() {
    // GTK4 requiere init explícito antes de tocar CssProvider/widgets
    // (el refresh loop usa load_from_data fuera de app.run()).
    gtk4::init().expect("Fallo al inicializar GTK");

    let app = gtk4::Application::builder()
        .application_id("com.loonbac.LoonBar")
        .build();

    // Provider de CSS compartido: connect_startup lo crea y conecta al
    // display; connect_activate (refresh loop) lo recarga si cambia el acento.
    let provider: Rc<RefCell<gtk4::CssProvider>> = Rc::new(RefCell::new(gtk4::CssProvider::new()));

    app.connect_startup({
        let provider = provider.clone();
        move |_| {
            let accent = load_accent();
            let css = bar_css(&accent);
            let p = provider.borrow();
            p.load_from_data(&css);

            if let Some(display) = gdk::Display::default() {
                let style_provider: gtk4::StyleProvider = p.clone().upcast();
                gtk4::style_context_add_provider_for_display(
                    &display,
                    &style_provider,
                    gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
                );
            }
        }
    });

    app.connect_activate(move |app| {
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("LoonBar")
            .default_height(48)
            .build();

        // Configuración de Layer Shell Nativo de Wayland:
        // Hace que la barra aparezca fija al frente de TODOS los workspaces, reserve espacio exclusivo de 48px y NO pida foco.
        window.init_layer_shell();
        window.set_namespace(Some("com.loonbac.LoonBar"));
        window.set_layer(Layer::Top);
        window.set_exclusive_zone(48);
        window.set_anchor(Edge::Bottom, true);
        window.set_anchor(Edge::Left, true);
        window.set_anchor(Edge::Right, true);
        window.set_keyboard_mode(KeyboardMode::None);

        let main_box = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);

        // --- Extremo Izquierdo: Logo de NixOS (solo ícono, sin botón) ---
        let start_btn = gtk4::Label::new(Some(""));
        start_btn.set_widget_name("start-btn");
        start_btn.set_selectable(false);
        start_btn.set_margin_start(14);
        start_btn.set_margin_end(14);
        start_btn.set_valign(gtk4::Align::Center);
        main_box.append(&start_btn);

        // --- Contenedor Único Agrupado de la Barra de Tareas ---
        let taskbar_group = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        taskbar_group.set_widget_name("taskbar-group");
        taskbar_group.set_margin_start(14);
        main_box.append(&taskbar_group);

        // Spacer expandible
        let spacer = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        main_box.append(&spacer);

        // --- System Tray: botón único (WiFi + Volumen + Batería) ---
        let tray_box = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        tray_box.set_widget_name("tray-box");
        tray_box.set_valign(gtk4::Align::Center);

        let sys_btn = gtk4::Label::new(Some("󰤨 󰕾 "));
        sys_btn.add_css_class("tray-icon");
        sys_btn.set_tooltip_text(Some("Sistema: WiFi, Volumen y Batería"));
        tray_box.append(&sys_btn);
        main_box.append(&tray_box);

        // --- Ventana del panel desplegable (layer-shell, anclada a la derecha, sobre la barra) ---
        let panel = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("Sistema")
            .default_width(320)
            .build();
        panel.init_layer_shell();
        panel.set_namespace(Some("com.loonbac.LoonBarPanel"));
        panel.set_layer(Layer::Top);
        // Sin exclusive zone: flota sobre el contenido, no empuja nada.
        panel.set_anchor(Edge::Right, true);
        panel.set_anchor(Edge::Bottom, true);
        panel.set_margin(Edge::Bottom, 48); // justo encima de la barra
        panel.set_keyboard_mode(KeyboardMode::OnDemand);

        let panel_box = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        panel_box.set_widget_name("sys-panel");
        panel.set_child(Some(&panel_box));

        // Título
        let title = gtk4::Label::new(Some("Sistema"));
        title.set_widget_name("sys-panel-title");
        title.set_xalign(0.0);
        panel_box.append(&title);

        // ---- Sección WiFi ----
        let wifi_toggle_row = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        wifi_toggle_row.add_css_class("sys-toggle-row");
        let wifi_toggle_label = gtk4::Label::new(Some("Wi-Fi"));
        wifi_toggle_label.add_css_class("sys-toggle-label");
        wifi_toggle_label.set_hexpand(true);
        wifi_toggle_label.set_xalign(0.0);
        wifi_toggle_row.append(&wifi_toggle_label);
        let wifi_switch = gtk4::Switch::new();
        wifi_switch.set_active(wifi_enabled());
        wifi_toggle_row.append(&wifi_switch);
        panel_box.append(&wifi_toggle_row);

        // Lista de redes
        let wifi_list = gtk4::ListBox::new();
        wifi_list.add_css_class("wifi-list");
        wifi_list.set_selection_mode(gtk4::SelectionMode::None);
        panel_box.append(&wifi_list);

        // Fila para conectar con contraseña (oculta hasta elegir red con candado)
        let password_row = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        password_row.set_visible(false);
        let pass_entry = gtk4::Entry::new();
        pass_entry.set_placeholder_text(Some("Contraseña de la red..."));
        pass_entry.set_visibility(false);
        pass_entry.add_css_class("wifi-password-entry");
        password_row.append(&pass_entry);
        let connect_btn = gtk4::Button::with_label("Conectar");
        connect_btn.add_css_class("sys-connect-btn");
        password_row.append(&connect_btn);
        panel_box.append(&password_row);

        // ---- Sección Volumen ----
        let vol_row = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        vol_row.add_css_class("sys-slider-row");
        let vol_icon = gtk4::Label::new(None);
        vol_icon.add_css_class("tray-icon");
        vol_row.append(&vol_icon);
        let vol_slider = gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 100.0, 2.0);
        vol_slider.set_draw_value(false);
        vol_slider.add_css_class("sys-slider");
        vol_slider.set_hexpand(true);
        vol_row.append(&vol_slider);
        panel_box.append(&vol_row);

        // ---- Sección Batería ----
        let batt_row = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        batt_row.add_css_class("sys-status-row");
        let batt_icon = gtk4::Label::new(None);
        batt_icon.add_css_class("tray-icon");
        batt_row.append(&batt_icon);
        let batt_label = gtk4::Label::new(None);
        batt_label.set_xalign(0.0);
        batt_row.append(&batt_label);
        panel_box.append(&batt_row);

        // ---- Estado compartido ----
        let selected_net: Rc<RefCell<Option<WifiNet>>> = Rc::new(RefCell::new(None));
        let dragging: Rc<Cell<bool>> = Rc::new(Cell::new(false));

        // ---- Eventos del panel ----

        // Slider de volumen: marcar arrastre para no pisar el valor mientras se mueve.
        {
            let dragging_p = dragging.clone();
            let dragging_r = dragging.clone();
            let vol_slider_r = vol_slider.clone();
            let gesture = gtk4::GestureClick::new();
            gesture.connect_pressed(move |_, _, _, _| {
                dragging_p.set(true);
            });
            gesture.connect_released(move |_, _, _, _| {
                dragging_r.set(false);
                // Al soltar, aplicar el volumen final.
                let val = vol_slider_r.value() as u32;
                volume_set(val);
            });
            vol_slider.add_controller(gesture);
        }

        // Toggle wifi
        {
            let wifi_switch_cb = wifi_switch.clone();
            let wifi_list = wifi_list.clone();
            let selected_net = selected_net.clone();
            let password_row = password_row.clone();
            let pass_entry = pass_entry.clone();
            let sys_btn = sys_btn.clone();
            let vol_icon = vol_icon.clone();
            let vol_slider = vol_slider.clone();
            let dragging = dragging.clone();
            let batt_icon = batt_icon.clone();
            let batt_label = batt_label.clone();
            wifi_switch.connect_state_set(move |_, active| {
                if active {
                    let _ = nmcli(&["radio", "wifi", "on"]);
                } else {
                    let _ = nmcli(&["radio", "wifi", "off"]);
                }
                refresh_wifi_list(&wifi_list, &selected_net, &password_row, &pass_entry);
                refresh_panel_state(
                    &sys_btn, &vol_icon, &vol_slider, &dragging, &batt_icon, &batt_label, &wifi_switch_cb,
                );
                gtk4::glib::Propagation::Proceed
            });
        }

        // Botón "Conectar" con la contraseña.
        {
            let selected_net = selected_net.clone();
            let pass_entry = pass_entry.clone();
            let password_row = password_row.clone();
            let wifi_list = wifi_list.clone();
            let sys_btn = sys_btn.clone();
            let vol_icon = vol_icon.clone();
            let vol_slider = vol_slider.clone();
            let dragging = dragging.clone();
            let batt_icon = batt_icon.clone();
            let batt_label = batt_label.clone();
            let wifi_switch_cb = wifi_switch.clone();
            connect_btn.connect_clicked(move |_| {
                let net = selected_net.borrow().clone();
                if let Some(net) = net {
                    let password = if net.security != "Abierta" {
                        Some(pass_entry.text().to_string())
                    } else {
                        None
                    };
                    let _ = wifi_connect(&net.ssid, password.as_deref());
                    password_row.set_visible(false);
                    pass_entry.set_text("");
                    refresh_wifi_list(&wifi_list, &selected_net, &password_row, &pass_entry);
                    refresh_panel_state(
                        &sys_btn, &vol_icon, &vol_slider, &dragging, &batt_icon, &batt_label, &wifi_switch_cb,
                    );
                }
            });
        }

        // Botón único de sistema: alternar visibilidad del panel.
        {
            let sys_btn_cb = sys_btn.clone();
            let panel = panel.clone();
            let wifi_list = wifi_list.clone();
            let selected_net = selected_net.clone();
            let password_row = password_row.clone();
            let pass_entry = pass_entry.clone();
            let vol_icon = vol_icon.clone();
            let vol_slider = vol_slider.clone();
            let dragging = dragging.clone();
            let batt_icon = batt_icon.clone();
            let batt_label = batt_label.clone();
            let wifi_switch_cb = wifi_switch.clone();
            let gesture = gtk4::GestureClick::new();
            gesture.connect_released(move |_, _, _, _| {
                if panel.is_visible() {
                    panel.hide();
                } else {
                    refresh_wifi_list(&wifi_list, &selected_net, &password_row, &pass_entry);
                    refresh_panel_state(
                        &sys_btn_cb, &vol_icon, &vol_slider, &dragging, &batt_icon, &batt_label, &wifi_switch_cb,
                    );
                    panel.present();
                }
            });
            sys_btn.add_controller(gesture);
        }

        // Refresco periódico del panel (cada 5s): redes, volumen, batería.
        {
            let wifi_list = wifi_list.clone();
            let selected_net = selected_net.clone();
            let password_row = password_row.clone();
            let pass_entry = pass_entry.clone();
            let sys_btn = sys_btn.clone();
            let vol_icon = vol_icon.clone();
            let vol_slider = vol_slider.clone();
            let dragging = dragging.clone();
            let batt_icon = batt_icon.clone();
            let batt_label = batt_label.clone();
            let wifi_switch = wifi_switch.clone();
            glib::timeout_add_seconds_local(5, move || {
                refresh_wifi_list(&wifi_list, &selected_net, &password_row, &pass_entry);
                refresh_panel_state(
                    &sys_btn, &vol_icon, &vol_slider, &dragging, &batt_icon, &batt_label, &wifi_switch,
                );
                glib::ControlFlow::Continue
            });
        }

        // --- Extremo Derecho: Reloj de 12 Horas Centrado ---
        let clock_label = gtk4::Label::new(None);
        clock_label.set_widget_name("clock-label");
        clock_label.set_justify(gtk4::Justification::Center);
        clock_label.set_valign(gtk4::Align::Center);
        main_box.append(&clock_label);

        // Actualizar reloj cada 1 segundo
        let clock_label_clone = clock_label.clone();
        glib::timeout_add_seconds_local(1, move || {
            let now = glib::DateTime::now_local().unwrap_or_else(|_| glib::DateTime::now_utc().unwrap());
            let time_str = now.format("%I:%M %p\n%d/%m/%Y").unwrap_or_default();
            clock_label_clone.set_text(&time_str);
            glib::ControlFlow::Continue
        });
        // Primera ejecución del reloj
        let now = glib::DateTime::now_local().unwrap_or_else(|_| glib::DateTime::now_utc().unwrap());
        if let Ok(time_str) = now.format("%I:%M %p\n%d/%m/%Y") {
            clock_label.set_text(&time_str);
        }

        // --- Actualización en tiempo real de la barra de tareas ---
        // IMPORTANTE: los botones NO se recrean en cada tick. Recrear
        // widgets cada 100ms rompe el render de GTK (el texto deja de
        // dibujarse). Solo se reconstruyen cuando cambia el conjunto de
        // apps (abrir/cerrar ventana); en los refrescos de foco solo se
        // actualiza la clase "active".
        let taskbar_group_clone = taskbar_group.clone();
        let refresh_taskbar = move || {
            let workspaces = fetch_workspaces();
            let groups = group_windows(fetch_windows(), &workspaces);

            // Claves actuales: (app_id, workspace_idx) en orden.
            let keys: Vec<(String, u64)> = groups
                .iter()
                .map(|g| (g.app_id.clone(), g.workspace_idx))
                .collect();

            // Estado anterior: las claves que ya tienen botón.
            let mut existing: Vec<(String, u64)> = Vec::new();
            let mut child = taskbar_group_clone.first_child();
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
                while let Some(child) = taskbar_group_clone.first_child() {
                    taskbar_group_clone.remove(&child);
                }

                if !groups.is_empty() {
                    taskbar_group_clone.set_visible(true);

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
                                taskbar_group_clone.append(&sep);
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

                        taskbar_group_clone.append(&btn);
                    }
                }
                if groups.is_empty() {
                    taskbar_group_clone.set_visible(false);
                }
            } else {
                // El conjunto de apps no cambió: solo actualizar la clase
                // "active" de cada botón (cambio de foco / workspace).
                let focused: Vec<(String, u64)> = groups
                    .iter()
                    .filter(|g| g.windows.iter().any(|w| w.is_focused))
                    .map(|g| (g.app_id.clone(), g.workspace_idx))
                    .collect();

                let mut child = taskbar_group_clone.first_child();
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
        };

        // Refresco inicial (la barra se pinta antes de que llegue el primer evento).
        refresh_taskbar();

        // Polling rápido con IPC directo por socket: cada fetch es ~1ms
        // (conectar + escribir request JSON + leer respuesta), así que un
        // intervalo de 100ms es barato y la barra reacciona casi al instante.
        // El event-stream de niri resultó poco fiable (conexiones que se
        // cuelgan sin cerrar y pierden eventos), así que no se usa.
        let provider = provider.clone();
        let mut last_accent_mtime: Option<std::time::SystemTime> = None;
        glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
            // Vigilar el archivo de acento: si cambió (otro wallpaper),
            // recargar el CSS para que la barra use el color nuevo.
            let accent_path = std::path::Path::new(
                &std::env::var("HOME").unwrap_or_default(),
            )
            .join(".config/mpvpaper/accent.txt");
            let mtime = std::fs::metadata(&accent_path).and_then(|m| m.modified()).ok();
            if mtime != last_accent_mtime {
                last_accent_mtime = mtime;
                let accent = load_accent();
                let css = bar_css(&accent);
                let p = provider.borrow();
                p.load_from_data(&css);
            }

            refresh_taskbar();
            glib::ControlFlow::Continue
        });

        window.set_child(Some(&main_box));
        window.present();
    });

    app.run();
}
