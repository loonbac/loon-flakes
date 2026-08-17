// Lógica pura (testeable): filtrado de apps y movimiento de selección.
use crate::models::{Item, ROWS};

/// Filtra las apps según la query.
/// - Si empieza por '>', filtra acciones de poder.
/// - Si empieza por '#', filtra fondos de pantalla (wallpapers).
/// - Si no, filtra apps por nombre.
pub fn filter_items(all_apps: &[Item], power: &[Item], wallpapers: &[Item], query: &str) -> Vec<Item> {
    let q = query.to_lowercase();
    let mut shown: Vec<Item> = Vec::new();

    if q.starts_with('>') {
        let filter = q[1..].trim().to_string();
        for p in power {
            if filter.is_empty() || p.name.to_lowercase().contains(&filter) {
                shown.push(p.clone());
            }
        }
    } else if q.starts_with('#') {
        let filter = q[1..].trim().to_string();
        for w in wallpapers {
            if filter.is_empty() || w.name.to_lowercase().contains(&filter) {
                shown.push(w.clone());
            }
        }
    } else {
        for app in all_apps {
            if app.name.to_lowercase().contains(&q) {
                shown.push(app.clone());
            }
        }
    }
    shown
}

/// Aplica un movimiento de selección (delta en celdas) y devuelve el nuevo índice.
/// - si no hay items devuelve -1
/// - si el índice actual es inválido, se ancla a 0
/// - clampa entre 0 y total-1
pub fn move_selection(sel: i32, delta: i32, total: usize) -> i32 {
    if total == 0 {
        return -1;
    }
    let mut idx = if sel < 0 { 0 } else { sel + delta };
    if idx < 0 {
        idx = 0;
    } else if idx >= total as i32 {
        idx = total as i32 - 1;
    }
    idx
}

/// Navegación en la lista de ROWS filas por columna:
/// - Abajo/Arriba se mueven +/-1 fila (dentro de la columna).
/// - Derecha/Izquierda se mueven en saltos de ROWS (siguiente/anterior columna).
pub fn move_sel_rowwise(sel: i32, delta: i32, total: usize) -> i32 {
    move_selection(sel, delta, total)
}

/// Normaliza la selección tras un repopulate: si quedó fuera de rango, 0.
pub fn normalize_selection(sel: i32, total: usize) -> i32 {
    if total == 0 {
        -1
    } else if sel < 0 || sel >= total as i32 {
        0
    } else {
        sel
    }
}

/// Escribe un carácter en el texto de búsqueda.
pub fn apply_char(text: &str, c: char) -> String {
    let mut s = text.to_string();
    s.push(c);
    s
}

/// Borra el último carácter.
pub fn apply_backspace(text: &str) -> String {
    let mut s = text.to_string();
    s.pop();
    s
}
