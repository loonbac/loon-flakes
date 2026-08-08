// Grid de apps: celdas en columnas de ROWS filas, scroll horizontal.
use gtk4::prelude::*;
use gtk4::{Image, Label, ListBoxRow, Orientation};
use std::cell::RefCell;
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
    pub fn repopulate(
        &self,
        all_apps: &[Item],
        power: &[Item],
        query: &str,
        sel: &Rc<RefCell<i32>>,
    ) -> Vec<Item> {
        while let Some(child) = self.grid.first_child() {
            self.grid.remove(&child);
        }

        let shown = filter_items(all_apps, power, query);
        let new_sel = normalize_selection(*sel.borrow(), shown.len());
        *sel.borrow_mut() = new_sel;

        for (i, item) in shown.iter().enumerate() {
            let cell = make_cell(item);
            // Columnas de ROWS filas: col 0 = filas 0..ROWS, col 1 = ROWS..2*ROWS...
            self.grid.attach(&cell, (i / ROWS) as i32, (i % ROWS) as i32, 1, 1);
            if i as i32 == new_sel {
                cell.add_css_class("selected");
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
fn make_cell(item: &Item) -> ListBoxRow {
    let cell = ListBoxRow::new();
    cell.set_size_request(CELL_W, ROW_H);

    let hbox = gtk4::Box::new(Orientation::Horizontal, 10);
    hbox.set_margin_top(4);
    hbox.set_margin_bottom(4);
    hbox.set_margin_start(10);
    hbox.set_margin_end(10);
    hbox.set_valign(gtk4::Align::Center);

    let image = Image::new();
    if let Some(icon) = resolve_icon(&item.icon) {
        image.set_paintable(Some(&icon));
    }
    image.set_pixel_size(28);
    image.set_size_request(28, 28);
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
