# Script "wallpaper-picker": selector unificado de fondos de pantalla.
# Lista en fuzzel TODOS los fondos disponibles:
#   - Videos de ~/Videos/Wallpapers  -> fondo ANIMADO (mpvpaper, por workspace)
#   - Imágenes de ~/Pictures/Wallpaper -> fondo ESTÁTICO (backdrop, detrás de todo)
# Según lo que elijas, aplica a la capa correspondiente sin tocar la otra.
#
# Uso:
#   wallpaper-picker           # abre el selector (fuzzel)
#   wallpaper-picker list      # imprime la lista combinada (para debug)
{ pkgs, lib, mpvpaper-wallpaper, niri-backdrop }:

let
  videosDir = "$HOME/Videos/Wallpapers";
  imagesDir = "$HOME/Pictures/Wallpaper";
in
pkgs.writeShellScriptBin "wallpaper-picker" ''
  set -euo pipefail

  VIDEOS_DIR="${videosDir}"
  IMAGES_DIR="${imagesDir}"
  FUZZEL="${pkgs.fuzzel}/bin/fuzzel"
  MPVPAPER_CMD="${mpvpaper-wallpaper}/bin/mpvpaper-wallpaper"
  BACKDROP_CMD="${niri-backdrop}/bin/niri-backdrop"

  list_all() {
    # Videos con prefijo [Video], imágenes con [Fondo], ordenados alfabéticamente.
    {
      find "$VIDEOS_DIR" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.gif' \) -printf '[Video] %f\n' 2>/dev/null
      find "$IMAGES_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '[Fondo] %f\n' 2>/dev/null
    } | sort -k2
  }

  case "''${1:-}" in
    list)
      list_all
      exit 0
      ;;
    *)
      SELECTION="$("$FUZZEL" --dmenu --placeholder "Elige un fondo (video animado o imagen de atrás)..." <<< "$(list_all)")"
      [ -z "$SELECTION" ] && exit 0

      KIND="''${SELECTION%% *}"   # "[Video]" o "[Fondo]"
      NAME="''${SELECTION#* }"    # el nombre del archivo

      case "$KIND" in
        "[Video]")
          "$MPVPAPER_CMD" set "$NAME"
          ;;
        "[Fondo]")
          "$BACKDROP_CMD" set "$NAME"
          ;;
        *)
          echo "Selección inválida: $SELECTION" >&2
          exit 1
          ;;
      esac
      ;;
  esac
''
