// Tema de íconos y caché compartidos: resolver/decodear íconos en cada
// tecla era el cuello de botella del launcher. Un solo IconTheme + caché
// hace el filtrado instantáneo.
use gtk4::prelude::*;
use gtk4::{IconLookupFlags, IconTheme};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;

thread_local! {
    static ICON_CACHE: RefCell<HashMap<String, Option<gtk4::IconPaintable>>> =
        RefCell::new(HashMap::new());
    static ICON_THEME: RefCell<Option<gtk4::IconTheme>> = RefCell::new(None);
}

pub fn resolve_icon(icon: &str) -> Option<gtk4::IconPaintable> {
    // Caché: la mayoría de apps comparten ícono (y las repopulaciones
    // repiten las mismas apps).
    if let Some(hit) = ICON_CACHE.with(|c| c.borrow().get(icon).cloned()) {
        return hit;
    }

    let theme = ICON_THEME.with(|t| t.borrow().clone()).unwrap_or_else(|| {
        // Tema global de GTK: usa el tema activo del sistema (Papirus-Dark)
        // y los search paths de iconos. IconTheme::new() crea un tema
        // aislado sin esos paths, y por eso no resolvía system-* ni otros.
        let display = gtk4::gdk::Display::default()
            .expect("no display disponible para resolver iconos");
        let t = gtk4::IconTheme::for_display(&display);
        ICON_THEME.with(|c| *c.borrow_mut() = Some(t.clone()));
        t
    });

    let paintable = if icon.starts_with('/') {
        // Ruta absoluta: solo si existe el archivo, carga perezosa.
        if Path::new(icon).is_file() {
            let file = gtk4::gio::File::for_path(icon);
            Some(gtk4::IconPaintable::for_file(&file, 28, 1))
        } else {
            None
        }
    } else {
        // Nombre del tema: solo si existe (evita el ícono "missing").
        if !theme.has_icon(icon) {
            None
        } else {
            // Sin FORCE_SYMBOLIC/PRELOAD: se pinta asíncronamente (carga
            // perezosa) y no bloquea el hilo de UI al filtrar.
            Some(theme.lookup_icon(
                icon,
                &[],
                28,
                1,
                gtk4::TextDirection::None,
                IconLookupFlags::empty(),
            ))
        }
    };

    ICON_CACHE.with(|c| c.borrow_mut().insert(icon.to_string(), paintable.clone()));
    paintable
}
