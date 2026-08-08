// Tema de la barra: color de acento dinámico y CSS completo.
//
// El acento se lee de ~/.config/mpvpaper/accent.txt (escrito por
// accent-wallpaper). Fallback: azul Windows 10 clásico.
use std::path::Path;

pub fn load_accent() -> String {
    let path = Path::new(&std::env::var("HOME").unwrap_or_default()).join(".config/mpvpaper/accent.txt");
    std::fs::read_to_string(&path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| s.starts_with('#') && s.len() == 7)
        .unwrap_or_else(|| "#0078d7".to_string())
}

/// Construye el CSS de la barra con el color de acento actual.
/// Usa @define-color para que el acento se aplique a la underbar de la app
/// activa, el botón "Conectar" y la red WiFi conectada.
pub fn bar_css(accent: &str) -> String {
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
