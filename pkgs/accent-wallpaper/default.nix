# Script "accent-wallpaper": extrae la paleta completa de colores del wallpaper activo.
#
# Toma un frame del fondo (video o imagen), analiza sus colores (ImageMagick + Python)
# y genera una paleta completa armónica que escribe en:
#   ~/.config/mpvpaper/accent.txt    -> hex del color de acento principal
#   ~/.config/niri/accent.kdl        -> override de niri (border active-color)
#   ~/.config/gtk-4.0/gtk.css        -> override de apps GTK (selección)
#   ~/.config/waybar/colors.css      -> paleta completa para Waybar (background, surface, foreground, accent, highlight, warning, critical, color0-15)
#   ~/.config/waybar/accent.css      -> compatibilidad de acento Waybar
#   ~/.config/swaync/accent.css      -> acento de notificaciones (SwayNC)
#
# Uso:
#   accent-wallpaper             # usa el wallpaper seteado (mpvpaper o backdrop)
#   accent-wallpaper from VIDEO  # analiza un video/imagen específico
{ pkgs, lib }:

let
  wallpapersDir = "$HOME/Videos/Wallpapers";
  backdropDir = "$HOME/Pictures/Wallpaper";
  stateFile = "$HOME/.config/mpvpaper/current.txt";
  backdropState = "$HOME/.config/mpvpaper/backdrop.txt";

  paletteExtractor = pkgs.writeText "extract-palette.py" ''
import sys
import os
import subprocess
import colorsys

def hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i+2], 16) / 255.0 for i in (0, 2, 4))

def rgb_to_hex(r, g, b):
    return '#{:02X}{:02X}{:02X}'.format(
        max(0, min(255, int(round(r * 255)))),
        max(0, min(255, int(round(g * 255)))),
        max(0, min(255, int(round(g * 255))))
    )

def get_luma(r, g, b):
    return 0.299 * r + 0.587 * g + 0.114 * b

def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    
    img_path = sys.argv[1]
    home = os.environ.get('HOME', '/home/loonbac')
    magick_bin = sys.argv[2] if len(sys.argv) > 2 else "magick"
    
    cmd = [magick_bin, img_path, '-colors', '16', '-format', '%c', 'histogram:info:']
    try:
        out = subprocess.check_output(cmd, text=True)
    except Exception as e:
        print(f"Error ejecutando ImageMagick: {e}", file=sys.stderr)
        sys.exit(1)
        
    colors = []
    for line in out.strip().splitlines():
        parts = line.strip().split()
        if not parts:
            continue
        try:
            count = int(parts[0].rstrip(':'))
        except ValueError:
            continue
        hex_candidates = [p for p in parts if p.startswith('#')]
        if not hex_candidates:
            continue
        hex_val = hex_candidates[0][:7].upper()
        if len(hex_val) != 7:
            continue
        try:
            r, g, b = hex_to_rgb(hex_val)
        except Exception:
            continue
        h, s, v = colorsys.rgb_to_hsv(r, g, b)
        luma = get_luma(r, g, b)
        colors.append({'count': count, 'hex': hex_val, 'r': r, 'g': g, 'b': b, 'h': h, 's': s, 'v': v, 'luma': luma})
        
    if not colors:
        print("No se pudieron extraer colores", file=sys.stderr)
        sys.exit(1)
        
    # 1. Accent: color más llamativo (alta saturación y buen brillo)
    accent_candidates = [c for c in colors if c['s'] >= 0.20 and 0.25 <= c['luma'] <= 0.85]
    if accent_candidates:
        accent_candidates.sort(key=lambda c: (c['s'] ** 1.2) * c['luma'] * (c['count'] ** 0.3), reverse=True)
        accent = accent_candidates[0]
    else:
        colors_by_sat = sorted(colors, key=lambda c: c['s'] * c['luma'], reverse=True)
        accent = colors_by_sat[0] if colors_by_sat else {'hex': '#5E81AC', 'r': 0.37, 'g': 0.51, 'b': 0.67, 'h': 0.58, 's': 0.45, 'v': 0.67, 'luma': 0.5}
        
    accent_hex = accent['hex']
    accent_h = accent.get('h', 0.58)
    
    # 2. Highlight / Color secundario de acento
    highlight_candidates = [c for c in colors if c['hex'] != accent_hex and abs(c['h'] - accent_h) > 0.08 and c['s'] >= 0.15]
    if highlight_candidates:
        highlight_candidates.sort(key=lambda c: c['s'] * c['luma'], reverse=True)
        highlight_hex = highlight_candidates[0]['hex']
    else:
        h_shift = (accent_h + 0.33) % 1.0
        hr, hg, hb = colorsys.hsv_to_rgb(h_shift, max(0.4, accent.get('s', 0.4)), max(0.6, accent.get('v', 0.6)))
        highlight_hex = rgb_to_hex(hr, hg, hb)
        
    # 3. Background y Surface: tono oscuro profundo y elegante derivado del wallpaper
    dark_colors = [c for c in colors if c['luma'] < 0.30]
    if dark_colors:
        dark_colors.sort(key=lambda c: c['count'], reverse=True)
        base_dark = dark_colors[0]
        dh, ds, dv = colorsys.rgb_to_hsv(base_dark['r'], base_dark['g'], base_dark['b'])
        bg_r, bg_g, bg_b = colorsys.hsv_to_rgb(dh, min(ds, 0.35), 0.10)
        surface_r, surface_g, surface_b = colorsys.hsv_to_rgb(dh, min(ds, 0.35), 0.16)
    else:
        bg_r, bg_g, bg_b = colorsys.hsv_to_rgb(accent_h, 0.20, 0.10)
        surface_r, surface_g, surface_b = colorsys.hsv_to_rgb(accent_h, 0.20, 0.16)
        
    bg_hex = rgb_to_hex(bg_r, bg_g, bg_b)
    surface_hex = rgb_to_hex(surface_r, surface_g, surface_b)
    
    # 4. Foreground: blanco roto nítido tintado con el matiz del wallpaper
    fg_r, fg_g, fg_b = colorsys.hsv_to_rgb(accent_h, 0.06, 0.94)
    fg_hex = rgb_to_hex(fg_r, fg_g, fg_b)
    
    # 5. Muted / Color sutil
    muted_r, muted_g, muted_b = colorsys.hsv_to_rgb(accent_h, 0.15, 0.55)
    muted_hex = rgb_to_hex(muted_r, muted_g, muted_b)
    
    # 6. Alertas / Estados
    warn_r, warn_g, warn_b = colorsys.hsv_to_rgb(0.10, 0.70, 0.90)
    crit_r, crit_g, crit_b = colorsys.hsv_to_rgb(0.97, 0.65, 0.90)
    warn_hex = rgb_to_hex(warn_r, warn_g, warn_b)
    crit_hex = rgb_to_hex(crit_r, crit_g, crit_b)
    
    on_accent_hex = '#000000' if accent['luma'] > 0.55 else '#FFFFFF'
    
    # Rutas de destino
    accent_txt_path = os.path.join(home, '.config/mpvpaper/accent.txt')
    niri_kdl_path = os.path.join(home, '.config/niri/accent.kdl')
    gtk_css_path = os.path.join(home, '.config/gtk-4.0/gtk.css')
    waybar_colors_path = os.path.join(home, '.config/waybar/colors.css')
    waybar_accent_path = os.path.join(home, '.config/waybar/accent.css')
    swaync_accent_path = os.path.join(home, '.config/swaync/accent.css')
    hypr_colors_path = os.path.join(home, '.config/hypr/colors.conf')
    
    for p in [accent_txt_path, niri_kdl_path, gtk_css_path, waybar_colors_path, waybar_accent_path, swaync_accent_path, hypr_colors_path]:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        
    with open(accent_txt_path, 'w') as f:
        f.write(accent_hex + '\n')
        
    with open(niri_kdl_path, 'w') as f:
        f.write(f'layout {{\n    border {{\n        active-color "{accent_hex}"\n    }}\n}}\n')
        
    with open(gtk_css_path, 'w') as f:
        f.write(f'@define-color accent {accent_hex};\n\n.nautilus-window .view:selected,\n.nautilus-window .view:selected:focus,\n.nautilus-window .sidebar .view:selected {{\n    background-color: @accent;\n    color: #ffffff;\n}}\n')
        
    waybar_colors_content = f"""/* Paleta dinámica generada desde el wallpaper */
@define-color background {bg_hex};
@define-color background_alt {surface_hex};
@define-color surface {surface_hex};
@define-color foreground {fg_hex};
@define-color accent {accent_hex};
@define-color on_accent {on_accent_hex};
@define-color highlight {highlight_hex};
@define-color muted {muted_hex};
@define-color warning {warn_hex};
@define-color critical {crit_hex};
@define-color transparent transparent;

@define-color color0 {bg_hex};
@define-color color1 {crit_hex};
@define-color color2 {accent_hex};
@define-color color3 {warn_hex};
@define-color color4 {highlight_hex};
@define-color color5 {muted_hex};
@define-color color6 {highlight_hex};
@define-color color7 {fg_hex};
@define-color color8 {surface_hex};
@define-color color9 {crit_hex};
@define-color color10 {accent_hex};
@define-color color11 {warn_hex};
@define-color color12 {highlight_hex};
@define-color color13 {muted_hex};
@define-color color14 {highlight_hex};
@define-color color15 {fg_hex};
"""
    with open(waybar_colors_path, 'w') as f:
        f.write(waybar_colors_content)
        
    with open(waybar_accent_path, 'w') as f:
        f.write(f'@define-color accent {accent_hex};\n@define-color on_accent {on_accent_hex};\n')
        
    with open(swaync_accent_path, 'w') as f:
        f.write(f'@define-color accent {accent_hex};\n@define-color on_accent {on_accent_hex};\n')
        
    hypr_colors_content = f"""# Paleta dinámica generada desde el wallpaper
$accent = rgb({accent_hex.lstrip('#')})
$accent_alpha = rgba({accent_hex.lstrip('#')}ff)
$on_accent = rgb({on_accent_hex.lstrip('#')})
$background = rgb({bg_hex.lstrip('#')})
$surface = rgb({surface_hex.lstrip('#')})
$surface_alpha = rgba({surface_hex.lstrip('#')}cc)
$foreground = rgb({fg_hex.lstrip('#')})
$highlight = rgb({highlight_hex.lstrip('#')})
$muted = rgb({muted_hex.lstrip('#')})
$warning = rgb({warn_hex.lstrip('#')})
$critical = rgb({crit_hex.lstrip('#')})
"""
    with open(hypr_colors_path, 'w') as f:
        f.write(hypr_colors_content)
        
    print(f"Paleta de wallpaper aplicada: Accent={accent_hex}, BG={bg_hex}, FG={fg_hex}, Highlight={highlight_hex}")

if __name__ == "__main__":
    main()
'';
in
pkgs.writeShellScriptBin "accent-wallpaper" ''
  set -euo pipefail

  DIR="${wallpapersDir}"
  BACKDROP_DIR="${backdropDir}"
  STATE="${stateFile}"
  BACKDROP_STATE="${backdropState}"
  FFMPEG="${pkgs.ffmpeg}/bin/ffmpeg"
  MAGICK="${pkgs.imagemagick}/bin/magick"
  PYTHON="${pkgs.python3}/bin/python3"
  WAYBAR="${pkgs.waybar}/bin/waybar"
  SWAYNC_CLIENT="${pkgs.swaynotificationcenter}/bin/swaync-client"

  pick_target() {
    # 1. State de video (mpvpaper)
    if [ -f "$STATE" ]; then
      NAME="$(cat "$STATE")"
      [ -f "$DIR/$NAME" ] && { echo "$DIR/$NAME"; return; }
    fi
    # 2. State de imagen backdrop
    if [ -f "$BACKDROP_STATE" ]; then
      NAME="$(cat "$BACKDROP_STATE")"
      [ -f "$BACKDROP_DIR/$NAME" ] && { echo "$BACKDROP_DIR/$NAME"; return; }
    fi
    # 3. Primer video disponible
    VID="$(find "$DIR" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.gif' \) -printf '%p\n' 2>/dev/null | sort | head -1 || true)"
    [ -n "$VID" ] && { echo "$VID"; return; }
    # 4. Primera imagen disponible
    find "$BACKDROP_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '%p\n' 2>/dev/null | sort | head -1 || true
  }

  TARGET=""
  case "''${1:-}" in
    from)
      TARGET="''${2:-}"
      [ -z "$TARGET" ] && { echo "Uso: accent-wallpaper from ARCHIVO" >&2; exit 1; }
      case "$TARGET" in
        */*) ;;
        *)
          if [ -f "$DIR/$TARGET" ]; then
            TARGET="$DIR/$TARGET"
          elif [ -f "$BACKDROP_DIR/$TARGET" ]; then
            TARGET="$BACKDROP_DIR/$TARGET"
          else
            echo "No existe: $TARGET" >&2
            exit 1
          fi
          ;;
      esac
      ;;
    *)
      TARGET="$(pick_target)"
      [ -z "$TARGET" ] && { echo "No se encontraron wallpapers en $DIR ni en $BACKDROP_DIR" >&2; exit 1; }
      ;;
  esac

  ACCENT_TMP="$(mktemp -d)"
  trap 'rm -rf "$ACCENT_TMP"' EXIT
  FRAME="$ACCENT_TMP/frame.png"

  # Extraer frame si es video, o redimensionar si es imagen estática
  case "''${TARGET##*.}" in
    mp4|webm|mkv|mov|gif|MP4|WEBM|MKV|MOV|GIF)
      "$FFMPEG" -v error -y -ss 2 -i "$TARGET" -frames:v 1 -vf "scale=96:54" "$FRAME" 2>/dev/null || \
      "$FFMPEG" -v error -y -ss 0 -i "$TARGET" -frames:v 1 -vf "scale=96:54" "$FRAME"
      ;;
    *)
      "$MAGICK" "$TARGET" -resize 96x54\! "$FRAME"
      ;;
  esac

  # Extraer la paleta y escribir los archivos de configuración
  "$PYTHON" "${paletteExtractor}" "$FRAME" "$MAGICK"

  # ---- Propagación en vivo ----
  # Reiniciar waybar para aplicar nueva paleta de inmediato
  if pgrep -x waybar >/dev/null 2>&1; then
    pkill -x waybar || true
    sleep 0.2
    setsid "$WAYBAR" >/dev/null 2>&1 &
  fi

  # Recargar notificaciones SwayNC
  "$SWAYNC_CLIENT" -R 2>/dev/null || true
''
