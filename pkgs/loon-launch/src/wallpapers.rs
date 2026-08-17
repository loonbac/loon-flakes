// Wallpapers: lista los fondos disponibles (videos animados e imágenes del
// backdrop) como Items del launcher, separados en dos secciones:
//   - "Fondo de pantalla": videos (mpvpaper, capa por workspace)
//   - "Background": imágenes (niri-backdrop, capa detrás de todo)
// Los videos se representan con un frame extraído con ffmpeg (cacheado en
// ~/.cache/loon-launch) para la miniatura.
use std::fs;
use std::path::Path;
use std::process::Command;

use crate::models::Item;

const VIDEOS_DIR: &str = "/home/loonbac/Videos/Wallpapers";
const IMAGES_DIR: &str = "/home/loonbac/Pictures/Wallpaper";
const CACHE_DIR: &str = "/home/loonbac/.cache/loon-launch/thumbs";

pub fn wallpapers() -> Vec<Item> {
    let mut items = Vec::new();
    // Sección 1: Fondo de pantalla (videos animados).
    items.push(Item::header("Fondo de pantalla"));
    collect_dir(VIDEOS_DIR, true, &mut items);
    // Sección 2: Background (imágenes estáticas del backdrop).
    items.push(Item::header("Background"));
    collect_dir(IMAGES_DIR, false, &mut items);
    items
}

fn collect_dir(dir: &str, is_video: bool, out: &mut Vec<Item>) {
    if !Path::new(dir).is_dir() {
        return;
    }
    if let Ok(entries) = fs::read_dir(dir) {
        let mut files: Vec<_> = entries
            .flatten()
            .filter(|e| {
                let ext = e
                    .path()
                    .extension()
                    .and_then(|x| x.to_str())
                    .unwrap_or("")
                    .to_lowercase();
                matches!(
                    ext.as_str(),
                    "png" | "jpg" | "jpeg" | "webp" | "mp4" | "webm" | "mkv" | "mov" | "gif"
                )
            })
            .collect();
        files.sort_by_key(|e| e.file_name());
        for entry in files {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            let thumb = if is_video {
                video_thumb(&path)
            } else {
                path.to_string_lossy().to_string()
            };
            let exec = if is_video {
                format!("mpvpaper-wallpaper set {}", shell_quote(&name))
            } else {
                format!("niri-backdrop set {}", shell_quote(&name))
            };
            out.push(Item::wallpaper(name, exec, thumb));
        }
    }
}

/// Extrae (y cachea) un frame de un video para usarlo de miniatura.
fn video_thumb(video: &Path) -> String {
    let Some(stem) = video.file_stem().and_then(|s| s.to_str()) else {
        return String::new();
    };
    fs::create_dir_all(CACHE_DIR).ok();
    let thumb = format!("{CACHE_DIR}/{stem}.jpg");
    if !Path::new(&thumb).is_file() {
        let _ = Command::new("ffmpeg")
            .args([
                "-y",
                "-ss",
                "00:00:01",
                "-i",
                video.to_str().unwrap_or(""),
                "-frames:v",
                "1",
                "-vf",
                "scale=128:-1",
                "-q:v",
                "4",
                &thumb,
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
    thumb
}

/// Escapa un argumento para sh (nombres con espacios).
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
