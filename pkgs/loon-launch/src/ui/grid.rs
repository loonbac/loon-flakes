// Grid de apps: celdas en columnas de ROWS filas, scroll horizontal.
use gtk4::prelude::*;
use gtk4::{Image, Label, ListBoxRow, Orientation};
use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

use crate::filter::{filter_items, normalize_selection};
use crate::icons::resolve_icon;
use crate::models::{Item, CELL_W, ROW_H, ROWS};

/// Referencias a los widgets del grid que usa el resto de la UI.
#[derive(Clone)]
pub struct GridRefs {
    pub grid: gtk4::Grid,
    pub scrolled: gtk4::ScrolledWindow,
}

impl GridRefs {
    /// Limpia el grid y lo vuelve a poblar con los items que matchean `query`.
    /// Devuelve los items mostrados (para ejecutar la selección).
    /// Las cabeceras de sección se adjuntan a lo ancho (span de columnas) y
    /// no son seleccionables: solo los items de wallpaper/apps se numeran.
    pub fn repopulate(
        &self,
        all_apps: &[Item],
        power: &[Item],
        wallpapers: &[Item],
        query: &str,
        sel: &Rc<RefCell<i32>>,
    ) -> Vec<Item> {
        while let Some(child) = self.grid.first_child() {
            self.grid.remove(&child);
        }

        let shown = filter_items(all_apps, power, wallpapers, query);
        // Índices de los items seleccionables (sin cabeceras).
        let selectable: Vec<usize> = shown
            .iter()
            .enumerate()
            .filter(|(_, it)| !it.is_header)
            .map(|(i, _)| i)
            .collect();
        let new_sel = normalize_selection(*sel.borrow(), selectable.len());
        *sel.borrow_mut() = new_sel;
        let sel_item = new_sel
            .try_into()
            .ok()
            .and_then(|n: usize| selectable.get(n).copied());

        let mut item_idx = 0usize; // índice de item seleccionable (para columnas)
        let mut row = 0i32; // fila base de la banda actual
        let mut header_row = 0i32; // fila del último header
        let mut items_in_section = 0usize; // items de la sección actual
        for (i, item) in shown.iter().enumerate() {
            let cell = make_cell(item);
            if item.is_header {
                if items_in_section > 0 {
                    // La banda anterior ocupó ceil(items/ROWS) filas tras su header.
                    row = header_row + 1 + ((items_in_section + ROWS - 1) / ROWS) as i32;
                }
                // Cabecera: ancho completo (span de todas las columnas).
                self.grid.attach(&cell, 0, row, 100, 1);
                header_row = row;
                row += 1;
                items_in_section = 0;
            } else {
                // Items normales: columnas de ROWS filas dentro de la banda.
                self.grid.attach(
                    &cell,
                    (item_idx / ROWS) as i32,
                    header_row + 1 + (item_idx % ROWS) as i32,
                    1,
                    1,
                );
                if Some(i) == sel_item {
                    cell.add_css_class("selected");
                }
                item_idx += 1;
                items_in_section += 1;
            }
        }

        shown
    }
}

/// Construye el grid + scrolled window.
pub fn build_grid() -> GridRefs {
    let grid = gtk4::Grid::new();
    grid.set_row_spacing(2);
    grid.set_column_spacing(2);
    grid.set_halign(gtk4::Align::Center);
    grid.set_valign(gtk4::Align::Start);
    grid.set_focusable(true);

    let scrolled = gtk4::ScrolledWindow::builder()
        .child(&grid)
        .hexpand(true)
        .vexpand(true)
        .min_content_height(180)
        .height_request(180)
        .hscrollbar_policy(gtk4::PolicyType::Automatic)
        .vscrollbar_policy(gtk4::PolicyType::Never)
        .build();

    GridRefs { grid, scrolled }
}

/// Celda del grid: fila con ícono a la izquierda y nombre al lado.
/// Las cabeceras de sección ocupan todo el ancho y no son seleccionables.
fn make_cell(item: &Item) -> ListBoxRow {
    let cell = ListBoxRow::new();

    if item.is_header {
        cell.set_size_request(-1, 30);
        cell.add_css_class("section-header-row");
        let label = Label::new(Some(&item.name));
        label.set_xalign(0.0);
        label.set_margin_start(12);
        label.add_css_class("section-header");
        cell.set_child(Some(&label));
        return cell;
    }

    cell.set_size_request(CELL_W, ROW_H);

    let hbox = gtk4::Box::new(Orientation::Horizontal, 10);
    hbox.set_margin_top(4);
    hbox.set_margin_bottom(4);
    hbox.set_margin_start(10);
    hbox.set_margin_end(10);
    hbox.set_valign(gtk4::Align::Center);

    let image = Image::new();
    if item.is_wallpaper {
        // Miniatura real del wallpaper (imagen o frame extraído del video).
        let thumb_path = Path::new(&item.icon);
        if thumb_path.is_file() {
            if let Ok(pixbuf) =
                gtk4::gdk_pixbuf::Pixbuf::from_file_at_scale(thumb_path, 64, 40, true)
            {
                image.set_from_pixbuf(Some(&pixbuf));
            }
        }
    } else if let Some(icon) = resolve_icon(&item.icon) {
        image.set_paintable(Some(&icon));
    }
    image.set_pixel_size(if item.is_wallpaper { 40 } else { 28 });
    image.set_size_request(if item.is_wallpaper { 64 } else { 28 }, 40);
    image.set_valign(gtk4::Align::Center);
    hbox.append(&image);

    let label = Label::new(Some(&item.name));
    label.set_xalign(0.0);
    label.set_halign(gtk4::Align::Start);
    label.set_hexpand(true);
    label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    label.add_css_class("app-name");
    hbox.append(&label);

    cell.set_child(Some(&hbox));
    cell
}
