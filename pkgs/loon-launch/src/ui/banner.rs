// Banner del launcher: imagen de fondo fija + entry de búsqueda.
use gtk4::prelude::*;

use crate::models::{BANNER_H, WIN_W};

pub struct BannerRefs {
    pub root: gtk4::Overlay,
    pub viewport: gtk4::DrawingArea,
    pub entry: gtk4::Entry,
}

pub fn build_banner() -> BannerRefs {
    let banner = gtk4::Overlay::new();
    banner.set_size_request(WIN_W, BANNER_H);
    banner.set_hexpand(true);
    banner.add_css_class("banner-viewport");

    let banner_viewport = gtk4::DrawingArea::new();
    banner_viewport.set_content_width(WIN_W);
    banner_viewport.set_content_height(BANNER_H);
    banner_viewport.set_size_request(WIN_W, BANNER_H);

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

    BannerRefs {
        root: banner,
        viewport: banner_viewport,
        entry,
    }
}

impl BannerRefs {
    pub fn apply_mode(&self, wallpaper: bool) {
        // El banner de apps no se toca. En fondos se oculta: no hay búsqueda.
        self.root.set_visible(!wallpaper);
        self.root.set_size_request(WIN_W, BANNER_H);
        self.viewport.set_content_width(WIN_W);
        self.viewport.set_content_height(BANNER_H);
        self.viewport.set_size_request(WIN_W, BANNER_H);
        self.entry.set_size_request(600, -1);
        self.entry.set_placeholder_text(Some(
            "Buscar app… (escribe '>' para acciones de poder)",
        ));
    }
}
