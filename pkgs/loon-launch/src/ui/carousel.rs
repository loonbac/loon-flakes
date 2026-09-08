// Carrusel de wallpapers inspirado en el image-picker de Omarchy.
//
// Se dibuja en un solo DrawingArea para poder recortar cada preview como un
// trapecio y animar tamaño/posición sin que el layout de GTK redimensione la
// ventana en cada frame.
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::AnimationExt;
use std::cell::{Cell, RefCell};
use std::path::Path;
use std::rc::Rc;

use crate::models::Item;

const EXPANDED_W: f64 = 768.0;
const EXPANDED_H: f64 = 475.0;
const SLICE_W: f64 = 108.0;
const SLICE_H: f64 = 432.0;
const SLICE_SPACING: f64 = -30.0;
const SKEW: f64 = 28.0;

#[derive(Clone)]
struct Preview {
    index: i32,
    pixbuf: Option<gtk4::gdk_pixbuf::Pixbuf>,
}

#[derive(Clone, Copy)]
struct Geometry {
    index: i32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    emphasis: f64,
    distance: f64,
}

#[derive(Clone)]
pub struct CarouselRefs {
    pub area: gtk4::DrawingArea,
    previews: Rc<RefCell<Vec<Preview>>>,
    position: Rc<Cell<f64>>,
    selected: Rc<Cell<i32>>,
    animation: Rc<RefCell<Option<adw::TimedAnimation>>>,
    on_click: Rc<RefCell<Option<Rc<dyn Fn(i32, bool)>>>>,
}

impl CarouselRefs {
    pub fn set_items(&self, items: &[Item], selected: i32) {
        let previews = items
            .iter()
            .filter(|item| !item.is_header)
            .enumerate()
            .map(|(index, item)| Preview {
                index: index as i32,
                pixbuf: load_preview(item),
            })
            .collect::<Vec<_>>();

        let selected = selected.clamp(0, previews.len().saturating_sub(1) as i32);
        *self.previews.borrow_mut() = previews;
        self.selected.set(selected);
        self.position.set(selected as f64);
        self.animation.borrow_mut().take();
        self.area.queue_draw();
    }

    pub fn set_on_click(&self, callback: Rc<dyn Fn(i32, bool)>) {
        *self.on_click.borrow_mut() = Some(callback);
    }

    pub fn set_selected(&self, index: i32, animate: bool) {
        let count = self.previews.borrow().len();
        if count == 0 || index < 0 || index >= count as i32 {
            return;
        }

        self.selected.set(index);
        let from = self.position.get();
        let count_f = count as f64;
        let current = from.rem_euclid(count_f);
        let mut delta = index as f64 - current;
        if delta > count_f / 2.0 {
            delta -= count_f;
        } else if delta < -count_f / 2.0 {
            delta += count_f;
        }
        let to = from + delta;

        self.animation.borrow_mut().take();
        if !animate || (to - from).abs() < 0.001 {
            self.position.set(index as f64);
            self.area.queue_draw();
            return;
        }

        let position = self.position.clone();
        let area = self.area.clone();
        let target = adw::CallbackAnimationTarget::new(move |value| {
            position.set(value);
            area.queue_draw();
        });
        let animation = adw::TimedAnimation::new(&self.area, from, to, 220, target);
        animation.set_easing(adw::Easing::EaseOutCubic);
        let position = self.position.clone();
        let area = self.area.clone();
        animation.connect_done(move |_| {
            position.set(index as f64);
            area.queue_draw();
        });
        animation.play();
        *self.animation.borrow_mut() = Some(animation);
    }
}

pub fn build_carousel() -> CarouselRefs {
    let area = gtk4::DrawingArea::new();
    area.set_hexpand(true);
    area.set_vexpand(true);
    area.set_focusable(true);
    area.add_css_class("wallpaper-carousel");

    let refs = CarouselRefs {
        area: area.clone(),
        previews: Rc::new(RefCell::new(Vec::new())),
        position: Rc::new(Cell::new(0.0)),
        selected: Rc::new(Cell::new(0)),
        animation: Rc::new(RefCell::new(None)),
        on_click: Rc::new(RefCell::new(None)),
    };

    area.set_draw_func({
        let previews = refs.previews.clone();
        let position = refs.position.clone();
        move |_, cr, width, height| {
            draw_carousel(cr, width as f64, height as f64, &previews.borrow(), position.get());
        }
    });

    let click = gtk4::GestureClick::new();
    click.connect_released({
        let previews = refs.previews.clone();
        let position = refs.position.clone();
        let selected = refs.selected.clone();
        let on_click = refs.on_click.clone();
        let area = area.clone();
        move |_, _, x, y| {
            let geometries = carousel_geometries(
                area.width() as f64,
                area.height() as f64,
                previews.borrow().len(),
                position.get(),
            );
            if let Some(hit) = geometries
                .iter()
                .filter(|g| point_in_geometry(**g, x, y))
                .min_by(|a, b| a.distance.total_cmp(&b.distance))
            {
                if let Some(callback) = on_click.borrow().as_ref() {
                    callback(hit.index, hit.index == selected.get());
                }
            }
        }
    });
    area.add_controller(click);

    refs
}

fn load_preview(item: &Item) -> Option<gtk4::gdk_pixbuf::Pixbuf> {
    let path = Path::new(&item.icon);
    if !path.is_file() {
        return None;
    }
    gtk4::gdk_pixbuf::Pixbuf::from_file_at_scale(path, 1152, 712, true).ok()
}

fn draw_carousel(
    cr: &gtk4::cairo::Context,
    width: f64,
    height: f64,
    previews: &[Preview],
    position: f64,
) {
    let mut geometries = carousel_geometries(width, height, previews.len(), position);
    // Los extremos se pintan primero y la tarjeta que ocupa el centro, al final.
    geometries.sort_by(|a, b| b.distance.total_cmp(&a.distance));

    for geometry in geometries {
        let Some(preview) = previews.iter().find(|p| p.index == geometry.index) else {
            continue;
        };
        draw_preview(cr, geometry, preview.pixbuf.as_ref());
    }
}

fn carousel_geometries(width: f64, height: f64, count: usize, position: f64) -> Vec<Geometry> {
    if count == 0 || width <= 0.0 || height <= 0.0 {
        return Vec::new();
    }

    // Reduce todo proporcionalmente en una pantalla estrecha, pero conserva
    // espacio para ver al menos una tira a cada lado de la preview central.
    let scale_w = ((width - 150.0) / EXPANDED_W).clamp(0.56, 1.0);
    let scale_h = ((height - 50.0) / EXPANDED_H).clamp(0.56, 1.0);
    let scale = scale_w.min(scale_h);
    let expanded_w = EXPANDED_W * scale;
    let expanded_h = EXPANDED_H * scale;
    let slice_w = SLICE_W * scale;
    let slice_h = SLICE_H * scale;
    let spacing = SLICE_SPACING * scale;
    let step = slice_w + spacing;
    let center_x = (width - expanded_w) / 2.0;
    let center_y = (height - expanded_h) / 2.0;
    let count_f = count as f64;
    let mut output = Vec::new();

    for index in 0..count {
        let mut relative = index as f64 - position.rem_euclid(count_f);
        if relative > count_f / 2.0 {
            relative -= count_f;
        } else if relative < -count_f / 2.0 {
            relative += count_f;
        }

        let emphasis = (1.0 - relative.abs()).clamp(0.0, 1.0);
        let eased = emphasis * emphasis * (3.0 - 2.0 * emphasis);
        let card_w = slice_w + (expanded_w - slice_w) * eased;
        let card_h = slice_h + (expanded_h - slice_h) * eased;
        let x = if relative <= -1.0 {
            center_x + relative * step
        } else if relative < 0.0 {
            lerp(center_x - step, center_x, relative + 1.0)
        } else if relative < 1.0 {
            lerp(center_x, center_x + expanded_w + spacing, relative)
        } else {
            center_x + expanded_w + spacing + (relative - 1.0) * step
        };
        let y = center_y + (expanded_h - card_h) / 2.0;

        // No procesa tarjetas completamente fuera del viewport.
        if x + card_w >= -2.0 && x <= width + 2.0 {
            output.push(Geometry {
                index: index as i32,
                x,
                y,
                width: card_w,
                height: card_h,
                emphasis: eased,
                distance: relative.abs(),
            });
        }
    }
    output
}

fn draw_preview(
    cr: &gtk4::cairo::Context,
    geometry: Geometry,
    pixbuf: Option<&gtk4::gdk_pixbuf::Pixbuf>,
) {
    let Geometry {
        x,
        y,
        width,
        height,
        emphasis,
        ..
    } = geometry;
    let scale = (width / EXPANDED_W).max(height / EXPANDED_H);
    let skew = (SKEW * scale).min(width * 0.28);

    let _ = cr.save();
    trapezoid_path(cr, x, y, width, height, skew);
    cr.clip();

    if let Some(pixbuf) = pixbuf {
        let pw = pixbuf.width().max(1) as f64;
        let ph = pixbuf.height().max(1) as f64;
        let image_scale = (width / pw).max(height / ph);
        let dx = x + (width - pw * image_scale) / 2.0;
        let dy = y + (height - ph * image_scale) / 2.0;
        cr.translate(dx, dy);
        cr.scale(image_scale, image_scale);
        cr.set_source_pixbuf(pixbuf, 0.0, 0.0);
        let _ = cr.paint();
        cr.identity_matrix();
    } else {
        cr.set_source_rgb(0.035, 0.04, 0.055);
        let _ = cr.paint();
    }

    // En Omarchy las tiras no seleccionadas llevan un tinte del 42%.
    cr.set_source_rgba(0.02, 0.025, 0.04, 0.42 * (1.0 - emphasis));
    let _ = cr.paint();
    let _ = cr.restore();

    trapezoid_path(cr, x, y, width, height, skew);
    cr.set_line_width(1.0 + 2.0 * emphasis);
    cr.set_source_rgba(0.82, 0.86, 1.0, 0.28 + 0.72 * emphasis);
    let _ = cr.stroke();
}

fn trapezoid_path(
    cr: &gtk4::cairo::Context,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    skew: f64,
) {
    cr.new_path();
    cr.move_to(x + skew, y);
    cr.line_to(x + width, y);
    cr.line_to(x + width - skew, y + height);
    cr.line_to(x, y + height);
    cr.close_path();
}

fn point_in_geometry(geometry: Geometry, px: f64, py: f64) -> bool {
    if py < geometry.y || py > geometry.y + geometry.height {
        return false;
    }
    let skew = (SKEW * (geometry.width / EXPANDED_W).max(geometry.height / EXPANDED_H))
        .min(geometry.width * 0.28);
    let progress = (py - geometry.y) / geometry.height.max(1.0);
    let left = geometry.x + skew * (1.0 - progress);
    let right = geometry.x + geometry.width - skew * progress;
    px >= left && px <= right
}

fn lerp(from: f64, to: f64, progress: f64) -> f64 {
    from + (to - from) * progress.clamp(0.0, 1.0)
}
