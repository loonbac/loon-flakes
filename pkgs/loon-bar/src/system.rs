// Utilidades de red (nmcli), audio (wpctl) y batería (sysfs).
// IMPORTANTE: nmcli ejecutas comandos que pueden demorar hasta 3 segundos.
// Para EVITAR que la interfaz GTK se congele o se vuelva lenta, toda la
// información del sistema se obtiene en un hilo en SEGUNDO PLANO y se guarda
// en un cache en memoria (RwLock). El hilo principal de GTK lee el cache
// instantáneamente en 0ms.

use std::process::Command;
use std::sync::{Arc, OnceLock, RwLock};
use std::thread;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct WifiNet {
    pub ssid: String,
    pub signal: u32,
    pub security: String,
    pub connected: bool,
}

#[derive(Debug, Clone, Default)]
pub struct SystemSnapshot {
    pub wifi_enabled: bool,
    pub wifi_nets: Vec<WifiNet>,
    pub connected_ssid: Option<String>,
    pub volume_pct: u32,
    pub volume_muted: bool,
    pub battery_pct: u32,
    pub battery_charging: bool,
}

static SYSTEM_CACHE: OnceLock<Arc<RwLock<SystemSnapshot>>> = OnceLock::new();

fn get_cache() -> &'static Arc<RwLock<SystemSnapshot>> {
    SYSTEM_CACHE.get_or_init(|| {
        let cache = Arc::new(RwLock::new(SystemSnapshot::default()));
        let cache_clone = cache.clone();

        // Hilo en segundo plano que actualiza el estado del sistema sin bloquear GTK
        thread::spawn(move || {
            loop {
                let snapshot = fetch_system_info_raw();
                if let Ok(mut lock) = cache_clone.write() {
                    *lock = snapshot;
                }
                thread::sleep(Duration::from_secs(4));
            }
        });

        cache
    })
}

/// Fuerza una actualización rápida en segundo plano (p.ej. al hacer click en conectar o toggle)
pub fn trigger_system_refresh() {
    let cache = get_cache().clone();
    thread::spawn(move || {
        let snapshot = fetch_system_info_raw();
        if let Ok(mut lock) = cache.write() {
            *lock = snapshot;
        }
    });
}

/// Función interna ejecutada únicamente en segundo plano
fn fetch_system_info_raw() -> SystemSnapshot {
    let wifi_on = nmcli_wifi_enabled_raw();
    let wifi_nets = if wifi_on { wifi_list_raw() } else { Vec::new() };
    let connected_ssid = wifi_nets.iter().find(|n| n.connected).map(|n| n.ssid.clone());
    let (vol_pct, vol_muted) = volume_state_raw();
    let (batt_pct, batt_charging) = battery_state_raw();

    SystemSnapshot {
        wifi_enabled: wifi_on,
        wifi_nets,
        connected_ssid,
        volume_pct: vol_pct,
        volume_muted: vol_muted,
        battery_pct: batt_pct,
        battery_charging: batt_charging,
    }
}

/// Ejecuta nmcli y devuelve stdout como String
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

fn nmcli_wifi_enabled_raw() -> bool {
    nmcli(&["radio", "wifi"])
        .map(|s| s.trim() == "enabled")
        .unwrap_or(false)
}

pub fn wifi_enabled() -> bool {
    get_cache().read().ok().map(|c| c.wifi_enabled).unwrap_or(false)
}

pub fn wifi_radio(on: bool) {
    if on {
        let _ = nmcli(&["radio", "wifi", "on"]);
    } else {
        let _ = nmcli(&["radio", "wifi", "off"]);
    }
    trigger_system_refresh();
}

fn wifi_list_raw() -> Vec<WifiNet> {
    let out = match nmcli(&["-t", "-e", "yes", "-f", "SSID,SIGNAL,SECURITY,ACTIVE", "dev", "wifi", "list"]) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    let mut nets = Vec::new();
    for line in out.lines() {
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

pub fn wifi_list() -> Vec<WifiNet> {
    get_cache().read().ok().map(|c| c.wifi_nets.clone()).unwrap_or_default()
}

pub fn wifi_connected_ssid() -> Option<String> {
    get_cache().read().ok().and_then(|c| c.connected_ssid.clone())
}

pub fn wifi_connect(ssid: &str, password: Option<&str>) -> Result<(), String> {
    let mut args: Vec<&str> = vec!["dev", "wifi", "connect", ssid];
    if let Some(p) = password {
        args.push("password");
        args.push(p);
    }
    let res = nmcli(&args).map(|_| ());
    trigger_system_refresh();
    res
}

pub fn wifi_disconnect() {
    let _ = nmcli(&["dev", "disconnect", "wifi"]);
    trigger_system_refresh();
}

fn volume_state_raw() -> (u32, bool) {
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

pub fn volume_state() -> (u32, bool) {
    get_cache()
        .read()
        .ok()
        .map(|c| (c.volume_pct, c.volume_muted))
        .unwrap_or((100, false))
}

pub fn volume_set(pct: u32) {
    let _ = Command::new("wpctl")
        .args(["set-volume", "@DEFAULT_AUDIO_SINK@", &format!("{:.2}", pct as f32 / 100.0)])
        .spawn();
    if let Ok(mut lock) = get_cache().write() {
        lock.volume_pct = pct;
    }
}

fn battery_state_raw() -> (u32, bool) {
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

pub fn battery_state() -> (u32, bool) {
    get_cache()
        .read()
        .ok()
        .map(|c| (c.battery_pct, c.battery_charging))
        .unwrap_or((100, false))
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
