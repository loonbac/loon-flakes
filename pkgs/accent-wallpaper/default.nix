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
#   ~/.config/gtk-3.0/gtk.css        -> acento GTK3 (blueman y el resto de apps GTK3)
#   ~/.config/mpvpaper/theme-mode.txt -> modo claro/oscuro derivado del luma
#
# Regla de accent (decisión del dueño): SOLO los fondos animados (video)
# actualizan el accent del sistema. Los backdrops estáticos (niri-backdrop)
# se ignoran: la paleta anterior se conserva. El header del launcher lee el
# accent de los animados desde ~/.config/mpvpaper/accent.txt (sin cambios).
#
# Uso:
#   accent-wallpaper             # usa el wallpaper seteado; no-op si es estático
#   accent-wallpaper from VIDEO  # analiza un video específico y publica
#   accent-wallpaper from IMAGEN # no-op intencional (el estático no publica)
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

def atomic_write(path, content):
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, 'w') as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, path)

def hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i+2], 16) / 255.0 for i in (0, 2, 4))

def rgb_to_hex(r, g, b):
    return '#{:02X}{:02X}{:02X}'.format(
        max(0, min(255, int(round(r * 255)))),
        max(0, min(255, int(round(g * 255)))),
        max(0, min(255, int(round(b * 255))))
    )

def get_luma(r, g, b):
    return 0.299 * r + 0.587 * g + 0.114 * b

def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    
    img_path = sys.argv[1]
    home = os.environ.get('HOME', '/home/saito')
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
        
    # 3. Modo claro/oscuro segun el brillo medio del wallpaper.
    #    Umbral 0.60 a proposito: el default del sistema es OSCURO (theme.nix)
    #    y solo se pasa a claro si el fondo es claramente claro. Si no hay
    #    wallpaper o la extraccion falla, el script sale antes de aca y se
    #    conserva el default oscuro. El modo se vuelca a theme-mode.txt y de
    #    ahi lo lee el shell para conmutar dconf (gtk-theme/color-scheme).
    total_px = sum(c['count'] for c in colors)
    mean_luma = sum(c['luma'] * c['count'] for c in colors) / total_px if total_px else 0.0
    theme_mode = 'light' if mean_luma >= 0.60 else 'dark'

    # 4. Background y Surface: derivados del wallpaper, en el tono del modo.
    if theme_mode == 'light':
        bright_colors = [c for c in colors if c['luma'] >= 0.60]
        if bright_colors:
            bright_colors.sort(key=lambda c: c['count'], reverse=True)
            base_bright = bright_colors[0]
            bh, bs, _bv = colorsys.rgb_to_hsv(base_bright['r'], base_bright['g'], base_bright['b'])
            bg_r, bg_g, bg_b = colorsys.hsv_to_rgb(bh, min(bs, 0.18), 0.97)
            surface_r, surface_g, surface_b = colorsys.hsv_to_rgb(bh, min(bs, 0.22), 0.93)
            shi_r, shi_g, shi_b = colorsys.hsv_to_rgb(bh, min(bs, 0.24), 0.89)
        else:
            bg_r, bg_g, bg_b = colorsys.hsv_to_rgb(accent_h, 0.10, 0.97)
            surface_r, surface_g, surface_b = colorsys.hsv_to_rgb(accent_h, 0.12, 0.93)
            shi_r, shi_g, shi_b = colorsys.hsv_to_rgb(accent_h, 0.14, 0.89)
    else:
        dark_colors = [c for c in colors if c['luma'] < 0.30]
        if dark_colors:
            dark_colors.sort(key=lambda c: c['count'], reverse=True)
            base_dark = dark_colors[0]
            dh, ds, dv = colorsys.rgb_to_hsv(base_dark['r'], base_dark['g'], base_dark['b'])
            bg_r, bg_g, bg_b = colorsys.hsv_to_rgb(dh, min(ds, 0.35), 0.10)
            surface_r, surface_g, surface_b = colorsys.hsv_to_rgb(dh, min(ds, 0.35), 0.16)
            shi_r, shi_g, shi_b = colorsys.hsv_to_rgb(dh, min(ds, 0.35), 0.22)
        else:
            bg_r, bg_g, bg_b = colorsys.hsv_to_rgb(accent_h, 0.20, 0.10)
            surface_r, surface_g, surface_b = colorsys.hsv_to_rgb(accent_h, 0.20, 0.16)
            shi_r, shi_g, shi_b = colorsys.hsv_to_rgb(accent_h, 0.20, 0.22)

    bg_hex = rgb_to_hex(bg_r, bg_g, bg_b)
    surface_hex = rgb_to_hex(surface_r, surface_g, surface_b)
    surface_high_hex = rgb_to_hex(shi_r, shi_g, shi_b)

    # 5. Foreground y muted: se invierten con el modo (texto oscuro sobre
    #    fondo claro, texto claro sobre fondo oscuro).
    if theme_mode == 'light':
        fg_r, fg_g, fg_b = colorsys.hsv_to_rgb(accent_h, 0.18, 0.12)
        muted_r, muted_g, muted_b = colorsys.hsv_to_rgb(accent_h, 0.15, 0.45)
    else:
        fg_r, fg_g, fg_b = colorsys.hsv_to_rgb(accent_h, 0.06, 0.94)
        muted_r, muted_g, muted_b = colorsys.hsv_to_rgb(accent_h, 0.15, 0.55)
    fg_hex = rgb_to_hex(fg_r, fg_g, fg_b)
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
    # GTK3: blueman y el resto de apps GTK3 leen ESTE archivo, no el de gtk-4.0.
    # Sin él, blueman es la única ventana que no adopta el color del wallpaper.
    gtk3_css_path = os.path.join(home, '.config/gtk-3.0/gtk.css')
    waybar_colors_path = os.path.join(home, '.config/waybar/colors.css')
    waybar_accent_path = os.path.join(home, '.config/waybar/accent.css')
    swaync_accent_path = os.path.join(home, '.config/swaync/accent.css')
    hypr_colors_path = os.path.join(home, '.config/hypr/colors.conf')
    theme_mode_path = os.path.join(home, '.config/mpvpaper/theme-mode.txt')
    
    for p in [accent_txt_path, niri_kdl_path, gtk_css_path, gtk3_css_path, waybar_colors_path, waybar_accent_path, swaync_accent_path, hypr_colors_path, theme_mode_path]:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        
    atomic_write(accent_txt_path, accent_hex + '\n')
    atomic_write(theme_mode_path, theme_mode + '\n')
    atomic_write(niri_kdl_path, f'layout {{\n    border {{\n        active-color "{accent_hex}"\n    }}\n}}\n')
    atomic_write(gtk_css_path, f'@define-color accent {accent_hex};\n\n.nautilus-window .view:selected,\n.nautilus-window .view:selected:focus,\n.nautilus-window .sidebar .view:selected {{\n    background-color: @accent;\n    color: #ffffff;\n}}\n')

    # GTK3 (blueman): los selectores salen del Adwaita embebido en libgtk-3.so
    # (.view:selected, switch:checked, label/entry selection). El CSS del
    # usuario corre en GTK_STYLE_PROVIDER_PRIORITY_USER, por encima del tema.
    # GTK3 no recarga el archivo en caliente: el color entra al reabrir la app.
    atomic_write(gtk3_css_path, (
        f'@define-color accent {accent_hex};\n'
        f'@define-color on_accent {on_accent_hex};\n'
        f'\n'
        f'/* Generado por accent-wallpaper: acento del wallpaper (GTK3). */\n'
        f'.view:selected,\n'
        f'.view:selected:focus,\n'
        f'.view text:selected,\n'
        f'label selection,\n'
        f'entry selection {{\n'
        f'    background-color: @accent;\n'
        f'    color: @on_accent;\n'
        f'}}\n'
        f'\n'
        f'switch:checked {{\n'
        f'    background-color: @accent;\n'
        f'}}\n'
        f'\n'
        f'progressbar progress,\n'
        f'treeview.view progressbar progress {{\n'
        f'    background-color: @accent;\n'
        f'}}\n'
    ))
        
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
    atomic_write(waybar_accent_path, f'@define-color accent {accent_hex};\n@define-color on_accent {on_accent_hex};\n')
    atomic_write(swaync_accent_path, (
        f'@define-color accent {accent_hex};\n'
        f'@define-color on_accent {on_accent_hex};\n'
        f'@define-color background {bg_hex};\n'
        f'@define-color surface {surface_hex};\n'
        f'@define-color surface_high {surface_high_hex};\n'
        f'@define-color text {fg_hex};\n'
        f'@define-color text_dim {muted_hex};\n'
    ))
        
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
    atomic_write(hypr_colors_path, hypr_colors_content)

    # Waybar observa este import. Publicarlo al final hace que la actualización
    # visual ocurra cuando el resto de consumidores ya tiene la misma paleta.
    atomic_write(waybar_colors_path, waybar_colors_content)
        
    print(f"Paleta de wallpaper aplicada: Modo={theme_mode}, Accent={accent_hex}, BG={bg_hex}, FG={fg_hex}, Highlight={highlight_hex}")

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
  SWAYNC_CLIENT="${pkgs.swaynotificationcenter}/bin/swaync-client"
  DCONF="${pkgs.dconf}/bin/dconf"
  CACHE_ROOT="$HOME/.cache/accent-wallpaper"
  RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/accent-wallpaper"

  atomic_copy() {
    local source=$1
    local target=$2
    local temporary="$target.tmp.$$"
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$target")"
    ${pkgs.coreutils}/bin/cp "$source" "$temporary"
    ${pkgs.coreutils}/bin/chmod 0644 "$temporary"
    ${pkgs.coreutils}/bin/mv -f "$temporary" "$target"
  }

  # Convierte theme-mode.txt en dconf. Es el único punto donde se decide el
  # modo claro/oscuro del sistema: GTK3/GTK4 leen `gtk-theme` y
  # Chromium/Equibop leen `color-scheme` (los dos mandos verificados con probe
  # sobre theme_bg_color y con A/B de prefers-color-scheme respectivamente).
  # `|| true` porque dconf necesita el bus de sesión y esta parte no debe
  # abortar la paleta si se corre en un arranque todavía sin sesión.
  apply_theme_mode() {
    local mode
    mode="$(cat "$HOME/.config/mpvpaper/theme-mode.txt" 2>/dev/null || true)"
    # Default explícito: oscuro. Cubre home nuevo y cualquier lectura fallida.
    [ "$mode" = "light" ] || mode="dark"

    if [ "$mode" = "light" ]; then
      "$DCONF" write /org/gnome/desktop/interface/gtk-theme "'Adwaita'" 2>/dev/null || true
      "$DCONF" write /org/gnome/desktop/interface/color-scheme "'prefer-light'" 2>/dev/null || true
      "$DCONF" write /org/gnome/desktop/interface/icon-theme "'Papirus'" 2>/dev/null || true
    else
      "$DCONF" write /org/gnome/desktop/interface/gtk-theme "'Adwaita-dark'" 2>/dev/null || true
      "$DCONF" write /org/gnome/desktop/interface/color-scheme "'prefer-dark'" 2>/dev/null || true
      "$DCONF" write /org/gnome/desktop/interface/icon-theme "'Papirus-Dark'" 2>/dev/null || true
    fi
    echo "Modo de apariencia: $mode"
  }

  apply_cached_palette() {
    local cache=$1
    atomic_copy "$cache/accent.txt" "$HOME/.config/mpvpaper/accent.txt"
    atomic_copy "$cache/niri-accent.kdl" "$HOME/.config/niri/accent.kdl"
    atomic_copy "$cache/gtk.css" "$HOME/.config/gtk-4.0/gtk.css"
    atomic_copy "$cache/gtk3.css" "$HOME/.config/gtk-3.0/gtk.css"
    atomic_copy "$cache/waybar-accent.css" "$HOME/.config/waybar/accent.css"
    atomic_copy "$cache/swaync-accent.css" "$HOME/.config/swaync/accent.css"
    atomic_copy "$cache/hypr-colors.conf" "$HOME/.config/hypr/colors.conf"
    atomic_copy "$cache/theme-mode.txt" "$HOME/.config/mpvpaper/theme-mode.txt"
    # Publicar el import observado por Waybar al final.
    atomic_copy "$cache/waybar-colors.css" "$HOME/.config/waybar/colors.css"
  }

  cache_current_palette() {
    local cache=$1
    local temporary
    ${pkgs.coreutils}/bin/mkdir -p "$CACHE_ROOT"
    temporary="$(${pkgs.coreutils}/bin/mktemp -d "$CACHE_ROOT/.palette.XXXXXX")"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/mpvpaper/accent.txt" "$temporary/accent.txt"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/niri/accent.kdl" "$temporary/niri-accent.kdl"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/gtk-4.0/gtk.css" "$temporary/gtk.css"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/gtk-3.0/gtk.css" "$temporary/gtk3.css"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/waybar/colors.css" "$temporary/waybar-colors.css"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/waybar/accent.css" "$temporary/waybar-accent.css"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/swaync/accent.css" "$temporary/swaync-accent.css"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/hypr/colors.conf" "$temporary/hypr-colors.conf"
    ${pkgs.coreutils}/bin/cp "$HOME/.config/mpvpaper/theme-mode.txt" "$temporary/theme-mode.txt"
    : > "$temporary/complete"
    ${pkgs.coreutils}/bin/mv -T "$temporary" "$cache" 2>/dev/null || \
      ${pkgs.coreutils}/bin/rm -rf "$temporary"
  }

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

  # Regla de accent: solo los fondos animados publican. Un backdrop estático
  # (o cualquier imagen) conserva la paleta anterior y sale con éxito, para
  # que los setters estáticos (niri-backdrop) no necesiten distinguir.
  # Va ANTES del cache: una imagen estática no debe ni abrir el lock.
  case "''${TARGET##*.}" in
    mp4|webm|mkv|mov|gif|MP4|WEBM|MKV|MOV|GIF)
      ;;
    *)
      echo "accent-wallpaper: fondo estático ($TARGET); se conserva la paleta anterior"
      exit 0
      ;;
  esac

  # Serializa escritores y reutiliza la paleta mientras el archivo fuente no
  # cambie. La clave usa ruta, tamaño y mtime; no lee videos grandes completos.
  ${pkgs.coreutils}/bin/mkdir -p "$RUNTIME_DIR" "$CACHE_ROOT"
  ${pkgs.coreutils}/bin/chmod 0700 "$RUNTIME_DIR" "$CACHE_ROOT"
  exec 9>"$RUNTIME_DIR/change.lock"
  ${pkgs.util-linux}/bin/flock 9
  CACHE_KEY="$({
    ${pkgs.coreutils}/bin/printf '%s\n' 'palette-v5'
    # %y incluye nanosegundos, evitando reutilizar una paleta obsoleta si un
    # archivo se reemplaza muy rápido por otro del mismo tamaño.
    ${pkgs.coreutils}/bin/stat --printf='%n\n%s\n%y\n' "$TARGET"
  } | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
  PALETTE_CACHE="$CACHE_ROOT/$CACHE_KEY"

  if [ -f "$PALETTE_CACHE/complete" ]; then
    apply_cached_palette "$PALETTE_CACHE"
    apply_theme_mode
    "$SWAYNC_CLIENT" -R 2>/dev/null || true
    echo "Paleta cacheada aplicada: $TARGET"
    exit 0
  fi

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
  cache_current_palette "$PALETTE_CACHE"
  apply_theme_mode

  # ---- Propagación en vivo ----
  # Waybar observa style.css y sus imports porque la configuración activa
  # reload_style_on_change. colors.css se aplica dentro del mismo proceso: no
  # enviar SIGUSR2 ni reiniciar la unidad, pues eso reconstruye las barras y
  # produce un parpadeo visible durante el crossfade del wallpaper.

  # Recargar notificaciones SwayNC
  "$SWAYNC_CLIENT" -R 2>/dev/null || true
''
