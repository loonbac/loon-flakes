# Script "accent-wallpaper": extrae el color de acento del wallpaper animado.
#
# Toma un frame del video del fondo (con ffmpeg), analiza sus colores
# (imagemagick) y escribe:
#   ~/.config/mpvpaper/accent.txt    -> hex del color más llamativo (ej. #ff5722)
#   ~/.config/niri/accent.kdl        -> override de niri (border active-color)
#   ~/.config/gtk-4.0/gtk.css        -> override de apps GTK (selección)
#   ~/.config/waybar/accent.css      -> acento de waybar (workspace activo, tray)
#   ~/.config/swaync/accent.css      -> acento de notificaciones (SwayNC)
#
# "El más llamativo" = el color más saturado × brillante, descartando los
# casi negros (para que el acento sea vivo, no un gris oscuro).
#
# Uso:
#   accent-wallpaper             # usa el video seteado (state de mpvpaper)
#   accent-wallpaper from VIDEO  # analiza un video específico
{ pkgs, lib }:

let
  wallpapersDir = "$HOME/Videos/Wallpapers";
  stateFile = "$HOME/.config/mpvpaper/current.txt";
  accentFile = "$HOME/.config/mpvpaper/accent.txt";
  accentKdl = "$HOME/.config/niri/accent.kdl";
  gtkCss = "$HOME/.config/gtk-4.0/gtk.css";
  waybarAccentCss = "$HOME/.config/waybar/accent.css";
  swayncAccentCss = "$HOME/.config/swaync/accent.css";
in
pkgs.writeShellScriptBin "accent-wallpaper" ''
  set -euo pipefail

  DIR="${wallpapersDir}"
  STATE="${stateFile}"
  ACCENT="${accentFile}"
  KDL="${accentKdl}"
  GTK_CSS="${gtkCss}"
  WAYBAR_ACCENT="${waybarAccentCss}"
  SWAYNC_ACCENT="${swayncAccentCss}"
  FFMPEG="${pkgs.ffmpeg}/bin/ffmpeg"
  MAGICK="${pkgs.imagemagick}/bin/magick"
  WAYBAR="${pkgs.waybar}/bin/waybar"
  SWAYNC_CLIENT="${pkgs.swaynotificationcenter}/bin/swaync-client"

  pick_video() {
    if [ -f "$STATE" ]; then
      NAME="$(cat "$STATE")"
      [ -f "$DIR/$NAME" ] && { echo "$DIR/$NAME"; return; }
    fi
    # Sin state (o borrado): primer video disponible.
    find "$DIR" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.gif' \) -printf '%p\n' | sort | head -1
  }

  # Convierte "#rrggbbaa" (o "#aarrggbb") de ImageMagick a "#rrggbb".
  normalize_hex() {
    local h="$1"
    case "$h" in
      # srgba(...): lo manejamos antes; aquí solo hex.
      \#??????????) echo "#''${h:1:2}''${h:3:2}''${h:5:2}";; # 8 dígitos: rrggbbaa
      \#????????) echo "#''${h:1:2}''${h:3:2}''${h:5:2}";;   # 8 dígitos (aarrggbb)
      \#??????) echo "$h";;
      *) echo "$h";;
    esac
  }

  # Texto legible sobre el acento: blanco si el acento es oscuro, negro si
  # es claro (luma perceptiva ITU-R BT.709; umbral 150 = sesgo a blanco).
  on_accent() {
    local hex="$1"
    local r=$(( 16#''${hex:1:2} )); local g=$(( 16#''${hex:3:2} )); local b=$(( 16#''${hex:5:2} ))
    local luma=$(( (r*299 + g*587 + b*114) / 1000 ))
    [ "$luma" -gt 150 ] && echo "#000000" || echo "#ffffff"
  }

  analyze() {
    local video="$1"
    # Variable global única (posix sh no tiene local en trap; y con set -u
    # el trap no debe ver la variable sin definir).
    ACCENT_TMP="$(mktemp -d)"
    trap 'rm -rf "$ACCENT_TMP"' EXIT
    frame="$ACCENT_TMP/frame.png"

    # Frame a los 2 segundos (lejos del fade-in), redimensionado para que el
    # análisis sea rápido y representativo.
    "$FFMPEG" -v error -y -ss 2 -i "$video" -frames:v 1 -vf "scale=96:54" "$frame"

    # Histograma de los 8 colores dominantes. Formato por línea, ej:
    #   12345: (16,16,16)  #101010  srgb(6.3%,6.3%,6.3%)
    "$MAGICK" "$frame" -colors 8 -format "%c" histogram:info: | while IFS= read -r line; do
      # Extraer el hex (#rrggbb) y el peso (primer número antes de ':').
      weight="''${line%%:*}"
      hex="$(printf '%s' "$line" | grep -oE '#[0-9a-fA-F]{6}' | head -1)"
      [ -z "$hex" ] && continue
      r=$(( 16#''${hex:1:2} )); g=$(( 16#''${hex:3:2} )); b=$(( 16#''${hex:5:2} ))
      # Brillo percibido (0-255) y saturación aproximada (max-min)/max.
      max=$r; [ "$g" -gt "$max" ] && max=$g; [ "$b" -gt "$max" ] && max=$b
      min=$r; [ "$g" -lt "$min" ] && min=$g; [ "$b" -lt "$min" ] && min=$b
      bright=$(( (r*299 + g*587 + b*114) / 1000 ))
      sat=$(( max==0 ? 0 : (max-min)*100/max ))
      # Score: saturación × brillo; descartar casi negros y grises.
      if [ "$bright" -gt 64 ] && [ "$sat" -gt 30 ]; then
        score=$(( sat * bright ))
        printf '%s %s\n' "$score" "$hex"
      fi
    done | sort -rn | head -1 | awk '{print $2}'
  }

  VIDEO=""
  case "''${1:-}" in
    from)
      VIDEO="''${2:-}"
      [ -z "$VIDEO" ] && { echo "Uso: accent-wallpaper from VIDEO" >&2; exit 1; }
      # Si es nombre simple (sin /), busca en la carpeta de wallpapers.
      case "$VIDEO" in
        */*) ;;
        *) [ -f "$DIR/$VIDEO" ] && VIDEO="$DIR/$VIDEO" || { echo "No existe: $VIDEO" >&2; exit 1; } ;;
      esac
      ;;
    *)
      VIDEO="$(pick_video)"
      [ -z "$VIDEO" ] && { echo "No hay videos en $DIR" >&2; exit 1; }
      ;;
  esac

  HEX="$(analyze "$VIDEO")"
  if [ -z "$HEX" ]; then
    echo "No se pudo extraer un color llamativo (¿video muy oscuro?)" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$ACCENT")" "$(dirname "$KDL")" \
           "$(dirname "$WAYBAR_ACCENT")" "$(dirname "$SWAYNC_ACCENT")"

  # Escribir si cambió, o si algún output no tiene el hex actual (primera vez
  # tras este upgrade: tmpfiles crea los accent.css con el default #5e81ac).
  if [ ! -f "$ACCENT" ] || [ "$(cat "$ACCENT" 2>/dev/null || true)" != "$HEX" ] \
     || ! grep -q "$HEX" "$GTK_CSS" 2>/dev/null \
     || ! grep -q "$HEX" "$WAYBAR_ACCENT" 2>/dev/null \
     || ! grep -q "$HEX" "$SWAYNC_ACCENT" 2>/dev/null; then
    echo "$HEX" > "$ACCENT"
    printf 'layout {\n    border {\n        active-color "%s"\n    }\n}\n' "$HEX" > "$KDL"
    # gtk.css: color de acento para apps GTK (Nautilus selección, etc.).
    mkdir -p "$(dirname "$GTK_CSS")"
    printf '@define-color accent %s;\n\n.nautilus-window .view:selected,\n.nautilus-window .view:selected:focus,\n.nautilus-window .sidebar .view:selected {\n    background-color: @accent;\n    color: #ffffff;\n}\n' "$HEX" > "$GTK_CSS"
    # Acento para waybar y SwayNC (archivos reales del usuario; el default
    # inicial lo crea tmpfiles en el boot).
    ON_ACCENT="$(on_accent "$HEX")"
    printf '@define-color accent %s;\n@define-color on_accent %s;\n' "$HEX" "$ON_ACCENT" > "$WAYBAR_ACCENT"
    printf '@define-color accent %s;\n@define-color on_accent %s;\n' "$HEX" "$ON_ACCENT" > "$SWAYNC_ACCENT"
    echo "Acento: $HEX"

    # ---- Propagación en vivo ----
    # niri recarga accent.kdl solo (lo vigila). GTK no aplica en vivo.
    # waybar: restart controlado — recarga config.jsonc + style.css (incluido
    # accent.css). niri no lo respawnea (spawn-at-startup solo al inicio de
    # sesión), por eso lo relanzamos con setsid. Alternativa ligera si la
    # versión instalada refresca CSS con señal: killall -SIGUSR2 waybar.
    if pgrep -x waybar >/dev/null 2>&1; then
      pkill -x waybar
      sleep 0.3
      setsid "$WAYBAR" >/dev/null 2>&1 &
    fi
    # swaync: recarga config + CSS en el daemon en ejecución.
    "$SWAYNC_CLIENT" -R 2>/dev/null || true
  fi
''
