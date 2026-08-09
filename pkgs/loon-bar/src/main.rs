// LoonBar — barra de tareas nativa Wayland para niri (estilo Windows 10).
//
// Este archivo solo hace el bootstrap: init GTK, ventana layer-shell,
// reloj y wiring de los módulos (taskbar, panel, tema). Toda la lógica
// vive en módulos hermanos:
//   - models.rs   : tipos IPC de niri y grupos
//   - niri.rs     : socket IPC, fetch de windows/workspaces
//   - grouping.rs : agrupación (app_id, workspace) y nombres/íconos
//   - actions.rs  : acciones de click (activar/ciclar ventanas)
//   - taskbar.rs  : render + refresco de la barra de tareas
//   - system.rs   : nmcli, wpctl, batería
//   - panel.rs    : panel desplegable (WiFi/Volumen/Batería)
//   - theme.rs    : acento dinámico y CSS
mod actions;
mod grouping;
mod models;
mod niri;
mod panel;
mod system;
mod taskbar;
mod theme;

use gtk4::gdk;
use gtk4::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::cell::RefCell;
use std::rc::Rc;

use theme::{bar_css, load_accent, load_active_css};

fn main() {
    // GTK4 requiere init explícito antes de tocar CssProvider/widgets
    // (el refresh loop usa load_from_data fuera de app.run()).
    gtk4::init().expect("Fallo al inicializar GTK");

    // Hilo de fondo que hace polling del socket de niri y publica el
    // snapshot. El hilo de GTK NUNCA toca el socket: así la UI no se
    // congela aunque niri tarde en responder.
    niri::spawn_niri_poller();

    let app = gtk4::Application::builder()
        .application_id("com.loonbac.LoonBar")
        .build();

    // Provider de CSS compartido: connect_startup lo crea y conecta al
    // display; connect_activate (refresh loop) lo recarga si cambia el acento.
    let provider: Rc<RefCell<gtk4::CssProvider>> = Rc::new(RefCell::new(gtk4::CssProvider::new()));

    app.connect_startup({
        let provider = provider.clone();
        move |_| {
            let css = load_active_css();
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
        // Hace que la barra aparezca fija al frente de TODOS los workspaces,
        // reserve espacio exclusivo de 48px y NO pida foco.
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

        // --- Panel desplegable de sistema (se construye solo, con sus eventos) ---
        let (panel, _wifi_list, _selected_net, _password_row, _pass_entry) =
            panel::build_system_panel(app, sys_btn.clone());
        let _ = panel; // el panel vive mientras viva la app

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

        // --- Barra de tareas: refresco inicial (el timeout de 100ms la repinta) ---
        taskbar::refresh_taskbar(&taskbar_group);

        // Polling rápido con IPC directo por socket: cada fetch es ~1ms
        // (conectar + escribir request JSON + leer respuesta), así que un
        // intervalo de 100ms es barato y la barra reacciona casi al instante.
        // El event-stream de niri resultó poco fiable (conexiones que se
        // cuelgan sin cerrar y pierden eventos), así que no se usa.
        //
        // El IPC real lo hace el hilo poller (niri.rs); aquí solo se
        // repinta si el snapshot cambió.
        let provider = provider.clone();
        let mut last_css_mtime: Option<std::time::SystemTime> = None;
        let mut last_seq: u64 = u64::MAX;
        glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
            // Vigilar accent.txt y custom.css: si cambian desde la web o el wallpaper,
            // recargar el CSS en caliente al instante (<100ms).
            let home = std::env::var("HOME").unwrap_or_default();
            let accent_path = std::path::Path::new(&home).join(".config/mpvpaper/accent.txt");
            let custom_css_path = std::path::Path::new(&home).join(".config/loon-bar/custom.css");

            let mtime_accent = std::fs::metadata(&accent_path).and_then(|m| m.modified()).ok();
            let mtime_custom = std::fs::metadata(&custom_css_path).and_then(|m| m.modified()).ok();
            let current_mtime = mtime_custom.max(mtime_accent);

            if current_mtime != last_css_mtime {
                last_css_mtime = current_mtime;
                let css = load_active_css();
                let p = provider.borrow();
                p.load_from_data(&css);
            }

            // Repintar solo si el snapshot de niri cambió.
            let (seq, _, _) = niri::current_snapshot();
            if seq != last_seq {
                last_seq = seq;
                taskbar::refresh_taskbar(&taskbar_group);
            }
            glib::ControlFlow::Continue
        });

        window.set_child(Some(&main_box));
        window.present();
    });

    app.run();
}
