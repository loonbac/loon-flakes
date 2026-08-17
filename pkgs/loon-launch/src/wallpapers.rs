// Wallpapers: lista los fondos disponibles (videos animados e imágenes del
// backdrop) como Items del launcher. Los videos se representan con un frame
// extraído con ffmpeg (cacheado en ~/.cache/loon-launch) para la miniatura.
use std::fs;
use std::path::Path;
use std::process::Command;

use crate::models::Item;

const VIDEOS_DIR: &str = "/home/loonbac/Videos/Wallpapers";
const IMAGES_DIR: &str = "/home/loonbac/Pictures/Wallpaper";
const CACHE_DIR: &str = "/home/loonbac/.cache/loon-launch/thumbs";

pub fn wallpapers() -> Vec<Item> {
    let mut items = Vec::new();
    for dir in [IMAGES_DIR, VIDEOS_DIR] {
        if !Path::new(dir).is_dir() {
            continue;
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
                let is_video = dir == VIDEOS_DIR;
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
                let label = if is_video {
                    format!("▶ {}", name)
                } else {
                    format!("🖼 {}", name)
                };
                items.push(Item::wallpaper(label, exec, thumb));
            }
        }
    }
    items
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
