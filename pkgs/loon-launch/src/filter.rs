// Lógica pura (testeable): filtrado de apps y movimiento de selección.
use crate::models::Item;

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

/// Tamaño 16:9 para 2 filas enteras (videos / fotos) en `area_h`.
pub fn wallpaper_card_size(area_w: i32, area_h: i32, cols: i32) -> (i32, i32) {
    let cols = cols.max(1);
    let hpad = 40;
    let gap = 16;
    let chrome = 80;
    let max_w = ((area_w - hpad - gap * (cols - 1)) / cols).clamp(120, 400);
    let max_h = ((area_h - chrome) / 2).clamp(72, 180);
    let h_from_w = (max_w * 9) / 16;
    if h_from_w <= max_h {
        (max_w, h_from_w)
    } else {
        ((max_h * 16) / 9, max_h)
    }
}

/// Posiciones (fila, col) de una galería envuelta: cada sección arranca en
/// una fila nueva y las cards se parten de `cols` en `cols`.
pub fn gallery_positions(section_counts: &[usize], cols: i32) -> Vec<(i32, i32)> {
    let cols = cols.max(1);
    let mut out = Vec::new();
    let mut row = 0i32;
    for &n in section_counts {
        if n == 0 {
            continue;
        }
        for i in 0..n {
            let col = (i as i32) % cols;
            if i > 0 && col == 0 {
                row += 1;
            }
            out.push((row, col));
        }
        row += 1;
    }
    out
}

/// Navegación 2D: `positions[i] = (row, col)` del item seleccionable i.
/// Abajo/arriba buscan la fila siguiente en la misma columna (o la más cercana).
/// Izquierda/derecha se mueven solo dentro de la fila. Si no hay celda, se queda.
pub fn move_sel_grid(sel: i32, drow: i32, dcol: i32, positions: &[(i32, i32)]) -> i32 {
    if positions.is_empty() {
        return -1;
    }
    let idx = if sel < 0 { 0 } else { sel as usize };
    if idx >= positions.len() {
        return 0;
    }
    if drow == 0 && dcol == 0 {
        return idx as i32;
    }
    let (r, c) = positions[idx];
    if dcol != 0 && drow == 0 {
        let target_c = c + dcol;
        return positions
            .iter()
            .enumerate()
            .find(|(_, &(rr, cc))| rr == r && cc == target_c)
            .map(|(i, _)| i as i32)
            .unwrap_or(idx as i32);
    }
    let mut best: Option<(i32, i32, i32)> = None;
    for (i, &(rr, cc)) in positions.iter().enumerate() {
        let rd = rr - r;
        let same_dir = if drow > 0 { rd > 0 } else { rd < 0 };
        if !same_dir {
            continue;
        }
        let key = (rd.abs(), (cc - c).abs(), i as i32);
        if best.is_none_or(|cur| key < cur) {
            best = Some(key);
        }
    }
    best.map(|(_, _, i)| i).unwrap_or(idx as i32)
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
