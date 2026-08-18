// Grid de apps: celdas en columnas de ROWS filas, scroll horizontal.
// Modo fondos: el mismo hueco, una fila de previews 16:9 grandes.
use gtk4::prelude::*;
use gtk4::{Image, Label, ListBoxRow, Orientation, Widget};
use libadwaita as adw;
use libadwaita::prelude::AnimationExt;
use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;
use std::time::Duration;

use crate::filter::{filter_items, normalize_selection, wallpaper_card_size};
use crate::icons::resolve_icon;
use crate::models::{Item, BANNER_H, CELL_W, ROW_H, ROWS, WIN_H, WIN_W, WP_COLS, WP_WIN_W};

/// Referencias a los widgets del grid que usa el resto de la UI.
#[derive(Clone)]
pub struct GridRefs {
    pub grid: gtk4::Grid,
    pub gallery: gtk4::Box,
    pub scrolled: gtk4::ScrolledWindow,
    pub wallpaper_mode: Rc<RefCell<bool>>,
    pub media: Rc<RefCell<Vec<gtk4::MediaFile>>>,
    pub activate: Rc<RefCell<Option<Rc<dyn Fn()>>>>,
    pub cards: Rc<RefCell<Vec<Widget>>>,
    pub positions: Rc<RefCell<Vec<(i32, i32)>>>,
    enter_anims: Rc<RefCell<Vec<adw::TimedAnimation>>>,
    scroll_anims: Rc<RefCell<Vec<adw::TimedAnimation>>>,
}

impl GridRefs {
    /// Limpia el grid y lo vuelve a poblar con los items que matchean `query`.
    /// `animate` solo en present/cambio de modo: no en cada tecla.
    pub fn repopulate(
        &self,
        all_apps: &[Item],
        power: &[Item],
        wallpapers: &[Item],
        query: &str,
        sel: &Rc<RefCell<i32>>,
        animate: bool,
    ) -> Vec<Item> {
        self.pause_media();
        self.media.borrow_mut().clear();
        self.cards.borrow_mut().clear();
        self.positions.borrow_mut().clear();
        self.enter_anims.borrow_mut().clear();
        self.scroll_anims.borrow_mut().clear();

        while let Some(child) = self.grid.first_child() {
            self.grid.remove(&child);
        }
        while let Some(child) = self.gallery.first_child() {
            self.gallery.remove(&child);
        }

        let shown = filter_items(all_apps, power, wallpapers, query);
        let wallpaper_mode = query.starts_with('#');
        *self.wallpaper_mode.borrow_mut() = wallpaper_mode;
        self.apply_chrome(wallpaper_mode);

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

        if wallpaper_mode {
            self.fill_gallery(&shown, sel_item, sel, animate);
        } else {
            self.fill_apps(&shown, sel_item, sel, animate);
        }

        shown
    }

    fn fill_gallery(
        &self,
        shown: &[Item],
        sel_item: Option<usize>,
        sel: &Rc<RefCell<i32>>,
        animate: bool,
    ) {
        let (cw, ch) = wallpaper_card_size(WP_WIN_W, WIN_H, WP_COLS);
        let mut cards_row: Option<gtk4::Box> = None;
        let mut row_i = -1i32;
        let mut col_i = 0i32;
        let mut selectable_idx = 0i32;
        for (i, item) in shown.iter().enumerate() {
            if item.is_header {
                let g = gtk4::Box::new(Orientation::Vertical, 4);
                g.set_halign(gtk4::Align::Fill);
                g.set_hexpand(true);
                g.set_vexpand(true);
                g.add_css_class("wallpaper-group");
                let header = Label::new(Some(&item.name));
                header.add_css_class("section-header");
                header.set_halign(gtk4::Align::Center);
                header.set_xalign(0.5);
                g.append(&header);
                let (strip, row) = section_strip(WP_WIN_W - 48, ch);
                g.append(&strip);
                self.gallery.append(&g);
                if animate {
                    animate_enter(&header, 40, &self.enter_anims);
                }
                cards_row = Some(row);
                row_i += 1;
                col_i = 0;
                continue;
            }
            if cards_row.is_none() {
                let row = gallery_row();
                self.gallery.append(&row);
                cards_row = Some(row);
                row_i = row_i.max(0);
            }
            let (cell, media) = make_wallpaper_card(item, cw, ch);
            if let Some(media) = media {
                self.media.borrow_mut().push(media);
            }
            if Some(i) == sel_item {
                cell.add_css_class("selected");
            }
            if let Some(row) = cards_row.as_ref() {
                row.append(&cell);
            }
            bind_click(&cell, selectable_idx, sel, self);
            self.positions.borrow_mut().push((row_i.max(0), col_i));
            self.cards.borrow_mut().push(cell.clone().upcast());
            if animate {
                animate_enter(&cell, ((col_i as u32) * 40).min(200), &self.enter_anims);
            }
            col_i += 1;
            selectable_idx += 1;
        }
    }

    fn fill_apps(
        &self,
        shown: &[Item],
        sel_item: Option<usize>,
        sel: &Rc<RefCell<i32>>,
        animate: bool,
    ) {
        let mut item_idx = 0usize;
        let mut row = 0i32;
        let mut header_row = 0i32;
        let mut items_in_section = 0usize;
        let mut selectable_idx = 0i32;
        for (i, item) in shown.iter().enumerate() {
            let (cell, _) = make_app_cell(item);
            if item.is_header {
                if items_in_section > 0 {
                    row = header_row + 1 + ((items_in_section + ROWS - 1) / ROWS) as i32;
                }
                self.grid.attach(&cell, 0, row, 100, 1);
                header_row = row;
                row += 1;
                items_in_section = 0;
            } else {
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
                bind_click(&cell, selectable_idx, sel, self);
                self.positions
                    .borrow_mut()
                    .push(((item_idx % ROWS) as i32, (item_idx / ROWS) as i32));
                self.cards.borrow_mut().push(cell.clone().upcast());
                if animate {
                    animate_enter(
                        &cell,
                        ((item_idx as u32) * 24).min(220),
                        &self.enter_anims,
                    );
                }
                item_idx += 1;
                items_in_section += 1;
                selectable_idx += 1;
            }
        }
    }

    pub fn apply_sel(&self, idx: i32) {
        let cards = self.cards.borrow();
        for (i, card) in cards.iter().enumerate() {
            if i as i32 == idx {
                card.add_css_class("selected");
            } else {
                card.remove_css_class("selected");
            }
        }
        if idx >= 0 {
            if let Some(card) = cards.get(idx as usize).cloned() {
                drop(cards);
                self.scroll_card(&card, true);
                let this = self.clone();
                let card = card.clone();
                glib::idle_add_local_once(move || {
                    this.scroll_card(&card, true);
                });
            }
        }
    }

    fn scroll_card(&self, card: &Widget, animate: bool) {
        // En fondos el scroll real es el strip de la fila, no el ScrolledWindow de afuera.
        let scrolled = nearest_scrolled(card).unwrap_or_else(|| self.scrolled.clone());
        let Some((x, y)) = card.translate_coordinates(&scrolled, 0.0, 0.0) else {
            return;
        };
        let w = f64::from(card.width().max(1));
        let ht = f64::from(card.height().max(1));
        let h = scrolled.hadjustment();
        let v = scrolled.vadjustment();
        // Dejar aire para el borde de la card: si no, al volver al primero
        // el scroll lo pega al recorte de la ventana.
        const PAD: f64 = 22.0;
        let mut hx = h.value();
        if x < PAD {
            hx = (h.value() + x - PAD).max(h.lower());
        } else if x + w > h.page_size() - PAD {
            hx = (h.value() + x + w - (h.page_size() - PAD))
                .min(h.upper() - h.page_size())
                .max(h.lower());
        }
        let mut vy = v.value();
        if y < PAD {
            vy = (v.value() + y - PAD).max(v.lower());
        } else if y + ht > v.page_size() - PAD {
            vy = (v.value() + y + ht - (v.page_size() - PAD))
                .min(v.upper() - v.page_size())
                .max(v.lower());
        }
        if animate {
            animate_adjustment(&scrolled, &h, hx, &self.scroll_anims);
            animate_adjustment(&scrolled, &v, vy, &self.scroll_anims);
        } else {
            h.set_value(hx);
            v.set_value(vy);
        }
    }

    pub fn pause_media(&self) {
        for media in self.media.borrow().iter() {
            media.pause();
        }
    }

    pub fn play_media(&self) {
        for media in self.media.borrow().iter() {
            media.play();
        }
    }

    fn apply_chrome(&self, wallpaper_mode: bool) {
        let well_w = if wallpaper_mode { WP_WIN_W } else { WIN_W };
        let well_h = if wallpaper_mode {
            WIN_H
        } else {
            WIN_H - BANNER_H
        };
        if wallpaper_mode {
            self.scrolled.set_child(Some(&self.gallery));
            self.scrolled.set_vscrollbar_policy(gtk4::PolicyType::Never);
            self.scrolled.set_hscrollbar_policy(gtk4::PolicyType::Never);
        } else {
            self.scrolled.set_child(Some(&self.grid));
            self.scrolled.set_vscrollbar_policy(gtk4::PolicyType::Never);
            // Automatic: si es Never, GTK ensancha la ventana para mostrar
            // todas las columnas. La barra se oculta por CSS.
            self.scrolled.set_hscrollbar_policy(gtk4::PolicyType::Automatic);
        }
        self.scrolled.set_size_request(well_w, well_h);
        self.scrolled.set_min_content_width(well_w);
        self.scrolled.set_max_content_width(well_w);
        self.scrolled.set_min_content_height(well_h);
        self.scrolled.set_max_content_height(well_h);
    }
}

/// Construye el grid + galería + scrolled window.
pub fn build_grid() -> GridRefs {
    let grid = gtk4::Grid::new();
    grid.set_row_spacing(2);
    grid.set_column_spacing(2);
    grid.set_halign(gtk4::Align::Center);
    grid.set_valign(gtk4::Align::Start);
    grid.set_focusable(true);

    let gallery = gtk4::Box::new(Orientation::Vertical, 0);
    gallery.add_css_class("wallpaper-gallery");
    gallery.set_halign(gtk4::Align::Fill);
    gallery.set_valign(gtk4::Align::Fill);
    gallery.set_hexpand(true);
    gallery.set_vexpand(true);
    gallery.set_focusable(true);

    let well_h = WIN_H - BANNER_H; // apps; el modo fondos lo cambia en apply_chrome
    let scrolled = gtk4::ScrolledWindow::builder()
        .child(&grid)
        .hexpand(false)
        .vexpand(false)
        .propagate_natural_width(false)
        .propagate_natural_height(false)
        .min_content_width(WIN_W)
        .max_content_width(WIN_W)
        .min_content_height(well_h)
        .max_content_height(well_h)
        .width_request(WIN_W)
        .height_request(well_h)
        .hscrollbar_policy(gtk4::PolicyType::Automatic)
        .vscrollbar_policy(gtk4::PolicyType::Never)
        .focusable(true)
        .build();

    GridRefs {
        grid,
        gallery,
        scrolled,
        wallpaper_mode: Rc::new(RefCell::new(false)),
        media: Rc::new(RefCell::new(Vec::new())),
        activate: Rc::new(RefCell::new(None)),
        cards: Rc::new(RefCell::new(Vec::new())),
        positions: Rc::new(RefCell::new(Vec::new())),
        enter_anims: Rc::new(RefCell::new(Vec::new())),
        scroll_anims: Rc::new(RefCell::new(Vec::new())),
    }
}

fn animate_adjustment(
    widget: &impl IsA<Widget>,
    adj: &gtk4::Adjustment,
    to: f64,
    hold: &Rc<RefCell<Vec<adw::TimedAnimation>>>,
) {
    let from = adj.value();
    if (from - to).abs() < 0.5 {
        return;
    }
    let adj = adj.clone();
    let target = adw::CallbackAnimationTarget::new(glib::clone!(
        #[strong]
        adj,
        move |v| {
            adj.set_value(v);
        }
    ));
    let anim = adw::TimedAnimation::new(widget, from, to, 260, target);
    anim.set_easing(adw::Easing::EaseOutCubic);
    anim.play();
    hold.borrow_mut().push(anim);
}

fn nearest_scrolled(widget: &Widget) -> Option<gtk4::ScrolledWindow> {
    let mut current = widget.parent();
    while let Some(p) = current {
        if let Ok(sw) = p.clone().downcast::<gtk4::ScrolledWindow>() {
            return Some(sw);
        }
        current = p.parent();
    }
    None
}

fn gallery_row() -> gtk4::Box {
    let row = gtk4::Box::new(Orientation::Horizontal, 16);
    row.set_halign(gtk4::Align::Center);
    row.set_hexpand(false);
    row.set_valign(gtk4::Align::Center);
    row.set_margin_start(22);
    row.set_margin_end(22);
    row.add_css_class("wallpaper-row");
    row
}

fn section_strip(view_w: i32, card_h: i32) -> (gtk4::ScrolledWindow, gtk4::Box) {
    let row = gallery_row();
    // CenterBox del ancho del viewport: 1 card queda al centro; 4 cards
    // ensanchan el box y el strip scrollea sin comprimirlas.
    let wrap = gtk4::CenterBox::new();
    wrap.set_hexpand(false);
    wrap.set_size_request(view_w, card_h);
    wrap.set_center_widget(Some(&row));

    let strip = gtk4::ScrolledWindow::builder()
        .hexpand(false)
        .vexpand(false)
        .halign(gtk4::Align::Center)
        .propagate_natural_width(false)
        .propagate_natural_height(false)
        .min_content_width(view_w)
        .max_content_width(view_w)
        .min_content_height(card_h)
        .max_content_height(card_h)
        .width_request(view_w)
        .height_request(card_h)
        .hscrollbar_policy(gtk4::PolicyType::Automatic)
        .vscrollbar_policy(gtk4::PolicyType::Never)
        .build();
    strip.set_child(Some(&wrap));
    (strip, row)
}

fn bind_click(
    cell: &impl IsA<Widget>,
    selectable_idx: i32,
    sel: &Rc<RefCell<i32>>,
    refs: &GridRefs,
) {
    let gesture = gtk4::GestureClick::new();
    gesture.connect_released(glib::clone!(
        #[strong]
        sel,
        #[strong]
        refs,
        move |_, _, _, _| {
            *sel.borrow_mut() = selectable_idx;
            refs.apply_sel(selectable_idx);
            if let Some(cb) = refs.activate.borrow().as_ref() {
                cb();
            }
        }
    ));
    cell.add_controller(gesture);
}

fn animate_enter(
    widget: &impl IsA<Widget>,
    delay_ms: u32,
    hold: &Rc<RefCell<Vec<adw::TimedAnimation>>>,
) {
    // Solo opacidad: animar márgenes cambia el tamaño de la ventana en cada frame.
    let w = widget.clone().upcast::<Widget>();
    w.set_opacity(0.0);
    let hold = hold.clone();
    glib::timeout_add_local_once(Duration::from_millis(delay_ms as u64), move || {
        let ww = w.clone();
        let target = adw::CallbackAnimationTarget::new(move |v| {
            ww.set_opacity(v);
        });
        let anim = adw::TimedAnimation::new(&w, 0.0, 1.0, 340, target);
        anim.set_easing(adw::Easing::EaseOutCubic);
        anim.play();
        hold.borrow_mut().push(anim);
    });
}

fn make_app_cell(item: &Item) -> (ListBoxRow, Option<gtk4::MediaFile>) {
    let cell = ListBoxRow::new();

    if item.is_header {
        cell.set_size_request(-1, 30);
        cell.add_css_class("section-header-row");
        let label = Label::new(Some(&item.name));
        label.set_xalign(0.0);
        label.set_margin_start(12);
        label.add_css_class("section-header");
        cell.set_child(Some(&label));
        return (cell, None);
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
    (cell, None)
}

fn make_wallpaper_card(
    item: &Item,
    card_w: i32,
    card_h: i32,
) -> (gtk4::AspectFrame, Option<gtk4::MediaFile>) {
    let media_path = if !item.media_path.is_empty() {
        Path::new(&item.media_path)
    } else {
        Path::new(&item.icon)
    };
    let ext = media_path
        .extension()
        .and_then(|x| x.to_str())
        .unwrap_or("")
        .to_lowercase();
    let is_video = matches!(ext.as_str(), "mp4" | "webm" | "mkv" | "mov");

    let mut held = None;
    let picture = if is_video && media_path.is_file() {
        let media = gtk4::MediaFile::for_filename(media_path);
        media.set_muted(true);
        media.set_loop(true);
        media.connect_prepared_notify(|m| {
            if m.is_prepared() {
                m.play();
            }
        });
        media.play();
        let pic = gtk4::Picture::for_paintable(&media);
        held = Some(media);
        pic
    } else if media_path.is_file() {
        gtk4::Picture::for_filename(media_path)
    } else if Path::new(&item.icon).is_file() {
        gtk4::Picture::for_filename(Path::new(&item.icon))
    } else {
        gtk4::Picture::new()
    };
    picture.set_content_fit(gtk4::ContentFit::Cover);
    picture.set_can_shrink(true);
    picture.set_halign(gtk4::Align::Fill);
    picture.set_valign(gtk4::Align::Fill);
    picture.set_hexpand(true);
    picture.set_vexpand(true);
    picture.add_css_class("wallpaper-preview");

    let overlay = gtk4::Overlay::new();
    overlay.set_overflow(gtk4::Overflow::Hidden);
    overlay.set_child(Some(&picture));

    let kind = Label::new(Some(if is_video { "Video" } else { "Foto" }));
    kind.add_css_class("wallpaper-kind");
    kind.set_halign(gtk4::Align::Start);
    kind.set_valign(gtk4::Align::Start);
    overlay.add_overlay(&kind);

    let label = Label::new(Some(&item.name));
    label.add_css_class("wallpaper-caption");
    label.set_xalign(0.5);
    label.set_halign(gtk4::Align::Fill);
    label.set_valign(gtk4::Align::End);
    label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    overlay.add_overlay(&label);

    let frame = gtk4::AspectFrame::new(0.5, 0.5, 16.0 / 9.0, false);
    frame.add_css_class("wallpaper-card");
    frame.set_size_request(card_w, card_h);
    frame.set_halign(gtk4::Align::Center);
    frame.set_valign(gtk4::Align::Center);
    frame.set_hexpand(false);
    frame.set_vexpand(false);
    frame.set_overflow(gtk4::Overflow::Hidden);
    frame.set_child(Some(&overlay));
    (frame, held)
}
