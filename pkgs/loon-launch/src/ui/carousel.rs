// Carrusel de wallpapers inspirado en el image-picker de Omarchy.
//
// Las previews son texturas GDK y se componen con nodos GSK. Esto mantiene el
// recorte trapezoidal en GPU y deja que el frame clock de GTK/Wayland marque
// cada frame de la animación, sin reescalar imágenes con Cairo en CPU.
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
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
    texture: Option<gtk4::gdk::Texture>,
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

mod imp {
    use super::*;
    use gtk4::subclass::prelude::*;

    #[derive(Default)]
    pub struct CarouselCanvas {
        pub(super) previews: RefCell<Vec<Preview>>,
        pub(super) position: Cell<f64>,
        pub(super) selected: Cell<i32>,
        pub(super) animation: RefCell<Option<adw::TimedAnimation>>,
        pub(super) on_click: RefCell<Option<Rc<dyn Fn(i32, bool)>>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for CarouselCanvas {
        const NAME: &'static str = "LoonWallpaperCarousel";
        type Type = super::CarouselCanvas;
        type ParentType = gtk4::Widget;
    }

    impl ObjectImpl for CarouselCanvas {}

    impl WidgetImpl for CarouselCanvas {
        fn snapshot(&self, snapshot: &gtk4::Snapshot) {
            let widget = self.obj();
            draw_carousel(
                snapshot,
                widget.width() as f64,
                widget.height() as f64,
                &self.previews.borrow(),
                self.position.get(),
            );
        }
    }
}

glib::wrapper! {
    pub struct CarouselCanvas(ObjectSubclass<imp::CarouselCanvas>)
        @extends gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl CarouselCanvas {
    fn new() -> Self {
        glib::Object::builder().build()
    }
}

#[derive(Clone)]
pub struct CarouselRefs {
    pub area: CarouselCanvas,
}

impl CarouselRefs {
    pub fn set_items(&self, items: &[Item], selected: i32) {
        let previews = items
            .iter()
            .filter(|item| !item.is_header)
            .enumerate()
            .map(|(index, item)| Preview {
                index: index as i32,
                texture: load_preview(item),
            })
            .collect::<Vec<_>>();

        let selected = selected.clamp(0, previews.len().saturating_sub(1) as i32);
        let imp = self.area.imp();
        *imp.previews.borrow_mut() = previews;
        imp.selected.set(selected);
        imp.position.set(selected as f64);
        imp.animation.borrow_mut().take();
        self.area.queue_draw();
    }

    pub fn set_on_click(&self, callback: Rc<dyn Fn(i32, bool)>) {
        *self.area.imp().on_click.borrow_mut() = Some(callback);
    }

    pub fn set_selected(&self, index: i32, animate: bool) {
        let imp = self.area.imp();
        let count = imp.previews.borrow().len();
        if count == 0 || index < 0 || index >= count as i32 {
            return;
        }

        imp.selected.set(index);
        let from = imp.position.get();
        let count_f = count as f64;
        let current = from.rem_euclid(count_f);
        let mut delta = index as f64 - current;
        if delta > count_f / 2.0 {
            delta -= count_f;
        } else if delta < -count_f / 2.0 {
            delta += count_f;
        }
        let to = from + delta;

        imp.animation.borrow_mut().take();
        if !animate || (to - from).abs() < 0.001 {
            imp.position.set(index as f64);
            self.area.queue_draw();
            return;
        }

        let area = self.area.clone();
        let target = adw::CallbackAnimationTarget::new(move |value| {
            area.imp().position.set(value);
            area.queue_draw();
        });
        let animation = adw::TimedAnimation::new(&self.area, from, to, 220, target);
        animation.set_easing(adw::Easing::EaseOutCubic);
        let area = self.area.clone();
        animation.connect_done(move |_| {
            area.imp().position.set(index as f64);
            area.queue_draw();
        });
        animation.play();
        *imp.animation.borrow_mut() = Some(animation);
    }
}

pub fn build_carousel() -> CarouselRefs {
    let area = CarouselCanvas::new();
    area.set_hexpand(true);
    area.set_vexpand(true);
    area.set_focusable(true);
    area.add_css_class("wallpaper-carousel");

    let click = gtk4::GestureClick::new();
    click.connect_released({
        let area = area.clone();
        move |_, _, x, y| {
            let imp = area.imp();
            let geometries = carousel_geometries(
                area.width() as f64,
                area.height() as f64,
                imp.previews.borrow().len(),
                imp.position.get(),
            );
            if let Some(hit) = geometries
                .iter()
                .filter(|geometry| point_in_geometry(**geometry, x, y))
                .min_by(|a, b| a.distance.total_cmp(&b.distance))
            {
                if let Some(callback) = imp.on_click.borrow().as_ref() {
                    callback(hit.index, hit.index == imp.selected.get());
                }
            }
        }
    });
    area.add_controller(click);

    CarouselRefs { area }
}

fn load_preview(item: &Item) -> Option<gtk4::gdk::Texture> {
    let path = Path::new(&item.icon);
    if !path.is_file() {
        return None;
    }
    let pixbuf = gtk4::gdk_pixbuf::Pixbuf::from_file_at_scale(path, 1152, 712, true).ok()?;
    Some(gtk4::gdk::Texture::for_pixbuf(&pixbuf))
}

fn draw_carousel(
    snapshot: &gtk4::Snapshot,
    width: f64,
    height: f64,
    previews: &[Preview],
    position: f64,
) {
    let mut geometries = carousel_geometries(width, height, previews.len(), position);
    // Los extremos se componen primero y la tarjeta central, al final.
    geometries.sort_by(|a, b| b.distance.total_cmp(&a.distance));

    for geometry in geometries {
        let Some(preview) = previews.iter().find(|preview| preview.index == geometry.index) else {
            continue;
        };
        snapshot_preview(snapshot, geometry, preview.texture.as_ref());
    }
}

fn carousel_geometries(width: f64, height: f64, count: usize, position: f64) -> Vec<Geometry> {
    if count == 0 || width <= 0.0 || height <= 0.0 {
        return Vec::new();
    }

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

fn snapshot_preview(
    snapshot: &gtk4::Snapshot,
    geometry: Geometry,
    texture: Option<&gtk4::gdk::Texture>,
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
    let path = trapezoid_path(x, y, width, height, skew);
    snapshot.push_fill(&path, gtk4::gsk::FillRule::Winding);

    let bounds = gtk4::graphene::Rect::new(x as f32, y as f32, width as f32, height as f32);
    if let Some(texture) = texture {
        let texture_w = texture.width().max(1) as f64;
        let texture_h = texture.height().max(1) as f64;
        let image_scale = (width / texture_w).max(height / texture_h);
        let image_w = texture_w * image_scale;
        let image_h = texture_h * image_scale;
        let image_bounds = gtk4::graphene::Rect::new(
            (x + (width - image_w) / 2.0) as f32,
            (y + (height - image_h) / 2.0) as f32,
            image_w as f32,
            image_h as f32,
        );
        snapshot.append_texture(texture, &image_bounds);
    } else {
        snapshot.append_color(&gtk4::gdk::RGBA::new(0.035, 0.04, 0.055, 1.0), &bounds);
    }

    let dim_alpha = (0.42 * (1.0 - emphasis)) as f32;
    if dim_alpha > 0.001 {
        snapshot.append_color(&gtk4::gdk::RGBA::new(0.02, 0.025, 0.04, dim_alpha), &bounds);
    }
    snapshot.pop();

    let stroke = gtk4::gsk::Stroke::new((1.0 + 2.0 * emphasis) as f32);
    let border = gtk4::gdk::RGBA::new(0.82, 0.86, 1.0, (0.28 + 0.72 * emphasis) as f32);
    snapshot.append_stroke(&path, &stroke, &border);
}

fn trapezoid_path(x: f64, y: f64, width: f64, height: f64, skew: f64) -> gtk4::gsk::Path {
    let builder = gtk4::gsk::PathBuilder::new();
    builder.move_to((x + skew) as f32, y as f32);
    builder.line_to((x + width) as f32, y as f32);
    builder.line_to((x + width - skew) as f32, (y + height) as f32);
    builder.line_to(x as f32, (y + height) as f32);
    builder.close();
    builder.to_path()
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
