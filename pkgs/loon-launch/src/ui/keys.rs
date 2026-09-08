// Manejo del teclado: flechas, enter, escape, backspace y escritura.
// La captura en la ventana evita que el Entry robe las flechas.
use glib::clone;
use gtk4::gdk::Key;
use gtk4::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

use crate::filter::{apply_backspace, apply_char, move_sel_grid, move_selection_wrap};
use crate::ui::grid::GridRefs;

#[derive(Clone)]
pub struct KeyState {
    pub grid_refs: GridRefs,
    pub entry: gtk4::Entry,
    pub sel_idx: Rc<RefCell<i32>>,
    pub hide: Rc<dyn Fn()>,
    pub run_selected: Rc<dyn Fn()>,
}

pub fn setup_key_controller(window: &gtk4::ApplicationWindow, state: KeyState) {
    let controller = gtk4::EventControllerKey::new();
    controller.connect_key_pressed(clone!(
        #[strong]
        state,
        move |_, key, _, _| {
            let apply_sel = {
                let refs = state.grid_refs.clone();
                let sel_ref = state.sel_idx.clone();
                move |new_idx: i32| {
                    *sel_ref.borrow_mut() = new_idx;
                    refs.apply_sel(new_idx);
                }
            };

            let positions = state.grid_refs.positions.borrow().clone();
            let current = *state.sel_idx.borrow();
            let wallpaper_mode = *state.grid_refs.wallpaper_mode.borrow();

            match key {
                Key::Escape => {
                    (state.hide)();
                    glib::Propagation::Stop
                }
                Key::Down => {
                    let next = if wallpaper_mode {
                        move_selection_wrap(current, 1, positions.len())
                    } else {
                        move_sel_grid(current, 1, 0, &positions)
                    };
                    apply_sel(next);
                    glib::Propagation::Stop
                }
                Key::Up => {
                    let next = if wallpaper_mode {
                        move_selection_wrap(current, -1, positions.len())
                    } else {
                        move_sel_grid(current, -1, 0, &positions)
                    };
                    apply_sel(next);
                    glib::Propagation::Stop
                }
                Key::Right => {
                    let next = if wallpaper_mode {
                        move_selection_wrap(current, 1, positions.len())
                    } else {
                        move_sel_grid(current, 0, 1, &positions)
                    };
                    apply_sel(next);
                    glib::Propagation::Stop
                }
                Key::Left => {
                    let next = if wallpaper_mode {
                        move_selection_wrap(current, -1, positions.len())
                    } else {
                        move_sel_grid(current, 0, -1, &positions)
                    };
                    apply_sel(next);
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
