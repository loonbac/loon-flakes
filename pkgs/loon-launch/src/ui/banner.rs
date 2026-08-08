// Banner del launcher: imagen de fondo fija + entry de búsqueda.
use gtk4::prelude::*;

pub fn build_banner() -> (gtk4::Overlay, gtk4::Entry) {
    let banner = gtk4::Overlay::new();
    banner.set_size_request(680, 180);
    banner.add_css_class("banner-viewport");

    let banner_viewport = gtk4::DrawingArea::new();
    banner_viewport.set_content_width(680);
    banner_viewport.set_content_height(180);
    banner_viewport.set_size_request(680, 180);

    let banner_pixbuf = gtk4::gdk_pixbuf::Pixbuf::from_file(
        "/home/loonbac/Descargas/cl_aesthetic_mix58.jpg",
    )
    .expect("failed to load launcher banner image");
    banner_viewport.set_draw_func(move |_, cr, _, _| {
        cr.set_source_pixbuf(&banner_pixbuf, -300.0, -123.5);
        let _ = cr.paint();
    });
    banner.set_child(Some(&banner_viewport));

    let entry = gtk4::Entry::new();
    entry.set_placeholder_text(Some("Buscar app… (escribe '>' para acciones de poder)"));
    entry.add_css_class("search-entry");
    entry.set_halign(gtk4::Align::Center);
    entry.set_valign(gtk4::Align::Center);
    entry.set_size_request(600, -1);
    banner.add_overlay(&entry);
    banner.set_measure_overlay(&entry, false);

    (banner, entry)
}
