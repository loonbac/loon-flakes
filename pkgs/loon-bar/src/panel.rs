// Panel desplegable de sistema (WiFi / Volumen / Batería).
// Construye los widgets, maneja sus eventos y el refresco periódico.
use gtk4::glib;
use gtk4::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

use crate::system::*;

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
    let sig = wifi_list().first().map(|n| n.signal).unwrap_or(0);
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

/// Construye el panel flotante de sistema y devuelve:
/// (panel, botón de la barra, wifi_list, selected_net, password_row, pass_entry).
///
/// `sys_btn` es el botón único de la barra (WiFi+Vol+Bat) que alterna el panel.
pub fn build_system_panel(
    app: &gtk4::Application,
    sys_btn: gtk4::Label,
) -> (
    gtk4::ApplicationWindow,
    gtk4::ListBox,
    Rc<RefCell<Option<WifiNet>>>,
    gtk4::Box,
    gtk4::Entry,
) {
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
            wifi_radio(active);
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
        let sys_btn_cb = sys_btn.clone();
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

    (panel, wifi_list, selected_net, password_row, pass_entry)
}
