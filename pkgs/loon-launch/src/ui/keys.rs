// Manejo del teclado: flechas, enter, escape, backspace y escritura.
// La captura en la ventana evita que el Entry robe las flechas.
use glib::clone;
use gtk4::gdk::Key;
use gtk4::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

use crate::filter::{apply_backspace, apply_char, move_sel_rowwise};
use crate::models::{CELL_W, ROWS};

#[derive(Clone)]
pub struct KeyState {
    pub grid: gtk4::Grid,
    pub scrolled: gtk4::ScrolledWindow,
    pub entry: gtk4::Entry,
    pub window: gtk4::ApplicationWindow,
    pub sel_idx: Rc<RefCell<i32>>,
    pub run_selected: Rc<dyn Fn()>,
}

pub fn setup_key_controller(window: &gtk4::ApplicationWindow, state: KeyState) {
    let controller = gtk4::EventControllerKey::new();
    controller.connect_key_pressed(clone!(
        #[strong]
        state,
        move |_, key, _, _| {
            let grid = &state.grid;
            let scrolled = &state.scrolled;

            // Total de celdas visibles en el grid.
            let total = || {
                let mut n = 0;
                let mut child = grid.first_child();
                while let Some(c) = child {
                    n += 1;
                    child = c.next_sibling();
                }
                n
            };

            // Mover la selección, repintar y hacer scroll SOLO cuando la
            // selección sale del viewport (navegar hasta el borde y recién
            // ahí desplazar).
            let grid_ref = grid.clone();
            let scrolled_ref = scrolled.clone();
            let sel_ref = state.sel_idx.clone();
            let apply_sel = move |new_idx: i32| {
                if new_idx < 0 {
                    *sel_ref.borrow_mut() = new_idx;
                    return;
                }
                *sel_ref.borrow_mut() = new_idx;
                let children = grid_ref.observe_children();
                for i in 0..children.n_items() {
                    if let Some(obj) = children.item(i) {
                        if let Ok(w) = obj.downcast::<gtk4::Widget>() {
                            if i as i32 == new_idx {
                                w.add_css_class("selected");
                            } else {
                                w.remove_css_class("selected");
                            }
                        }
                    }
                }
                // Scroll horizontal SOLO si la celda sale de la vista.
                let col = (new_idx as usize) / ROWS;
                let h = scrolled_ref.hadjustment();
                let cell_x = (col as f64) * (CELL_W as f64);
                let cell_w = CELL_W as f64;
                let cur = h.value();
                let page = h.page_size();
                if cell_x < cur {
                    // Se salió por la izquierda: volver hasta mostrarla.
                    h.set_value(cell_x.max(h.lower()));
                } else if cell_x + cell_w > cur + page {
                    // Se salió por la derecha: scrollear lo mínimo para
                    // que la celda quede completa a la vista.
                    h.set_value((cell_x + cell_w - page).min(h.upper() - page).max(h.lower()));
                }
            };

            match key {
                Key::Escape => {
                    state.window.close();
                    glib::Propagation::Stop
                }
                Key::Down => {
                    // Abajo baja por la columna (siguiente fila).
                    let current = *state.sel_idx.borrow();
                    apply_sel(move_sel_rowwise(current, 1, total()));
                    glib::Propagation::Stop
                }
                Key::Up => {
                    // Arriba sube por la columna (anterior fila).
                    let current = *state.sel_idx.borrow();
                    apply_sel(move_sel_rowwise(current, -1, total()));
                    glib::Propagation::Stop
                }
                Key::Right => {
                    // Derecha va a la siguiente columna (salta ROWS filas).
                    let current = *state.sel_idx.borrow();
                    apply_sel(move_sel_rowwise(current, ROWS as i32, total()));
                    glib::Propagation::Stop
                }
                Key::Left => {
                    // Izquierda va a la columna anterior.
                    let current = *state.sel_idx.borrow();
                    apply_sel(move_sel_rowwise(current, -(ROWS as i32), total()));
                    glib::Propagation::Stop
                }
                Key::Return | Key::KP_Enter => {
                    (state.run_selected)();
                    glib::Propagation::Stop
                }
                Key::BackSpace => {
                    let text = state.entry.text().to_string();
                    state.entry.set_text(&apply_backspace(&text));
                    state.entry.set_position(-1);
                    glib::Propagation::Stop
                }
                _ => {
                    // Teclas imprimibles: escribir en la barra y filtrar.
                    if let Some(c) = key.to_unicode() {
                        if !c.is_control() {
                            let text = state.entry.text().to_string();
                            state.entry.set_text(&apply_char(&text, c));
                            state.entry.set_position(-1);
                        }
                        glib::Propagation::Stop
                    } else {
                        glib::Propagation::Proceed
                    }
                }
            }
        },
    ));
    controller.set_propagation_phase(gtk4::PropagationPhase::Capture);
    window.add_controller(controller);
}
