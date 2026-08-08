// Utilidades de red (nmcli), audio (wpctl) y batería (sysfs).
use std::process::Command;

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
pub fn wifi_enabled() -> bool {
    nmcli(&["radio", "wifi"])
        .map(|s| s.trim() == "enabled")
        .unwrap_or(false)
}

pub fn wifi_radio(on: bool) {
    if on {
        let _ = nmcli(&["radio", "wifi", "on"]);
    } else {
        let _ = nmcli(&["radio", "wifi", "off"]);
    }
}

/// Red WiFi: ssid, señal (%), seguridad (WPA2, Abierta...), conectada.
#[derive(Debug, Clone)]
pub struct WifiNet {
    pub ssid: String,
    pub signal: u32,
    pub security: String,
    pub connected: bool,
}

/// Lista las redes WiFi visibles (nmcli -t -e yes -f SSID,SIGNAL,SECURITY,ACTIVE).
pub fn wifi_list() -> Vec<WifiNet> {
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
pub fn wifi_connected_ssid() -> Option<String> {
    wifi_list().into_iter().find(|n| n.connected).map(|n| n.ssid)
}

/// Conecta a una red WiFi; si requiere contraseña y no está guardada, usa password.
pub fn wifi_connect(ssid: &str, password: Option<&str>) -> Result<(), String> {
    let mut args: Vec<&str> = vec!["dev", "wifi", "connect", ssid];
    if let Some(p) = password {
        args.push("password");
        args.push(p);
    }
    nmcli(&args).map(|_| ())
}

pub fn wifi_disconnect() {
    let _ = nmcli(&["dev", "disconnect", "wifi"]);
}

/// Estado del volumen: porcentaje y mute.
pub fn volume_state() -> (u32, bool) {
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

pub fn volume_set(pct: u32) {
    let _ = Command::new("wpctl")
        .args(["set-volume", "@DEFAULT_AUDIO_SINK@", &format!("{:.2}", pct as f32 / 100.0)])
        .spawn();
}

/// Estado de batería: porcentaje y si está cargando.
pub fn battery_state() -> (u32, bool) {
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

pub fn battery_icon(cap: u32, charging: bool) -> &'static str {
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

pub fn wifi_icon(signal: u32, connected: bool) -> &'static str {
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

pub fn volume_icon(pct: u32, muted: bool) -> &'static str {
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
