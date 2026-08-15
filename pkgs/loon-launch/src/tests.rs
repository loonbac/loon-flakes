// Tests de la lógica pura del launcher (filtrado, navegación, edición).
use crate::apps::power_actions;
use crate::filter::{
    apply_backspace, apply_char, filter_items, move_sel_rowwise, move_selection, normalize_selection,
};
use crate::models::{Item, ROWS};

fn app(name: &str) -> Item {
    Item { name: name.to_string(), exec: "true".to_string(), icon: "x".to_string() }
}

fn power() -> Vec<Item> {
    power_actions()
}

#[test]
fn filter_matches_by_name_case_insensitive() {
    let apps = vec![app("Firefox"), app("Ghostty"), app("VS Code")];
    let got = filter_items(&apps, &power(), "fire");
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].name, "Firefox");
}

#[test]
fn filter_empty_query_returns_all() {
    let apps = vec![app("A"), app("B")];
    let got = filter_items(&apps, &power(), "");
    assert_eq!(got.len(), 2);
}

#[test]
fn filter_power_mode_prefix() {
    let apps = vec![app("Firefox")];
    let got = filter_items(&apps, &power(), ">apag");
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].name, "Apagar");
}

#[test]
fn filter_power_empty_shows_all_power() {
    let got = filter_items(&[], &power(), ">");
    assert_eq!(got.len(), power().len());
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
        Item {
            name: "TikTok".to_string(),
            exec: "waydroid app launch com.zhiliaoapp.musically".to_string(),
            icon: "x".to_string(),
        },
        Item {
            name: "TikTok".to_string(),
            exec: "waydroid-app com.zhiliaoapp.musically".to_string(),
            icon: "x".to_string(),
        },
    ];
    apps.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| b.exec.contains("waydroid-app").cmp(&a.exec.contains("waydroid-app")))
    });
    apps.dedup_by(|a, b| a.name.to_lowercase() == b.name.to_lowercase());
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].exec, "waydroid-app com.zhiliaoapp.musically");
}
