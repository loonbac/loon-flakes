// Tests de la lógica pura del launcher (filtrado, navegación, edición).
use crate::apps::{data_dirs, power_actions};
use crate::filter::{
    apply_backspace, apply_char, filter_items, move_sel_grid, move_sel_rowwise, move_selection,
    move_selection_wrap, normalize_selection,
};
use crate::models::{Item, ROWS};
use crate::ui::parse_logical_size;

fn app(name: &str) -> Item {
    Item::app(name, "true", "x")
}

fn wallpaper(name: &str) -> Item {
    Item::wallpaper(name, "true", "/tmp/thumb.jpg")
}

fn power() -> Vec<Item> {
    power_actions()
}

#[test]
fn filter_matches_by_name_case_insensitive() {
    let apps = vec![app("Firefox"), app("Ghostty"), app("VS Code")];
    let got = filter_items(&apps, &power(), &[], "fire");
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].name, "Firefox");
}

#[test]
fn filter_empty_query_returns_all() {
    let apps = vec![app("A"), app("B")];
    let got = filter_items(&apps, &power(), &[], "");
    assert_eq!(got.len(), 2);
}

#[test]
fn filter_power_mode_prefix() {
    let apps = vec![app("Firefox")];
    let got = filter_items(&apps, &power(), &[], ">apag");
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].name, "Apagar");
}

#[test]
fn filter_power_empty_shows_all_power() {
    let got = filter_items(&[], &power(), &[], ">");
    assert_eq!(got.len(), power().len());
}

#[test]
fn filter_wallpaper_mode_prefix() {
    let wps = vec![wallpaper("▶ reze.mp4"), wallpaper("🖼 Asa.png")];
    let got = filter_items(&[], &[], &wps, "#reze");
    assert_eq!(got.len(), 1);
    assert!(got[0].name.contains("reze"));
}

#[test]
fn filter_wallpaper_empty_shows_all() {
    let wps = vec![wallpaper("▶ a.mp4"), wallpaper("🖼 b.png")];
    let got = filter_items(&[], &[], &wps, "#");
    assert_eq!(got.len(), 2);
}

#[test]
fn move_sel_right_steps_one() {
    assert_eq!(move_selection(0, 1, 10), 1);
    assert_eq!(move_selection(9, 1, 10), 9); // clampa al final
}

#[test]
fn move_sel_left_clamps_at_zero() {
    assert_eq!(move_selection(0, -1, 10), 0);
    assert_eq!(move_selection(1, -1, 10), 0);
}

#[test]
fn move_sel_down_steps_rows() {
    // En la lista de ROWS filas, Derecha salta ROWS (siguiente columna).
    assert_eq!(move_sel_rowwise(0, ROWS as i32, 20), ROWS as i32);
    assert_eq!(move_sel_rowwise(18, ROWS as i32, 20), 19); // clampa
}

#[test]
fn move_sel_empty_returns_neg1() {
    assert_eq!(move_selection(0, 1, 0), -1);
}

#[test]
fn move_sel_from_invalid_anchors_to_zero() {
    // sel inválido (-1) se ancla a 0 (primera celda).
    assert_eq!(move_selection(-1, 1, 10), 0);
    assert_eq!(move_selection(-1, -1, 10), 0);
}

#[test]
fn normalize_sel_resets_out_of_range() {
    assert_eq!(normalize_selection(5, 3), 0);
    assert_eq!(normalize_selection(-2, 3), 0);
    assert_eq!(normalize_selection(2, 3), 2);
    assert_eq!(normalize_selection(0, 0), -1);
}

#[test]
fn char_and_backspace_edit_text() {
    assert_eq!(apply_char("gh", 'o'), "gho");
    assert_eq!(apply_backspace("gho"), "gh");
    assert_eq!(apply_backspace(""), "");
}

#[test]
fn dedup_prefers_waydroid_app_wrapper() {
    let mut apps = vec![
        Item::app(
            "Android Notes",
            "waydroid app launch com.example.notes",
            "x",
        ),
        Item::app("Android Notes", "waydroid-app com.example.notes", "x"),
    ];
    apps.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| b.exec.contains("waydroid-app").cmp(&a.exec.contains("waydroid-app")))
    });
    apps.dedup_by(|a, b| a.name.to_lowercase() == b.name.to_lowercase());
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].exec, "waydroid-app com.example.notes");
}

#[test]
fn wallpaper_carousel_wraps_in_both_directions() {
    assert_eq!(move_selection_wrap(0, -1, 5), 4);
    assert_eq!(move_selection_wrap(4, 1, 5), 0);
    assert_eq!(move_selection_wrap(2, 1, 5), 3);
    assert_eq!(move_selection_wrap(0, 1, 0), -1);
}

#[test]
fn apps_grid_right_stays_on_same_row() {
    // Column-major 4-row grid: idx 0=(0,0), 1=(1,0), 4=(0,1)
    let pos: Vec<(i32, i32)> = (0..8).map(|i| ((i % 4) as i32, (i / 4) as i32)).collect();
    assert_eq!(move_sel_grid(0, 1, 0, &pos), 1);
    assert_eq!(move_sel_grid(0, 0, 1, &pos), 4);
    assert_eq!(move_sel_grid(3, 1, 0, &pos), 3);
    assert_eq!(move_sel_grid(0, -1, 0, &pos), 0);
}

#[test]
fn app_discovery_includes_dynamic_flatpak_exports() {
    let dirs = data_dirs();
    assert!(dirs
        .iter()
        .any(|dir| dir == std::path::Path::new("/var/lib/flatpak/exports/share")));

    if let Some(home) = std::env::var_os("HOME") {
        let user_exports =
            std::path::PathBuf::from(home).join(".local/share/flatpak/exports/share");
        assert!(dirs.contains(&user_exports));
    }
}

#[test]
fn parses_niri_logical_output_size() {
    let output = "Output \"monitor\" (HDMI-A-1)\n  Logical size: 1080x1920\n  Scale: 1\n";
    assert_eq!(parse_logical_size(output), Some((1080, 1920)));
    assert_eq!(parse_logical_size("no output"), None);
}
