# Script "niri-backdrop": fondo estático en el backdrop de niri.
# El backdrop es la capa global que se ve detrás de todo (entre workspaces,
# en el overview y a través de ventanas transparentes con xray).
# Atrás del video animado de cada workspace, este pone una imagen fija.
#
# Uso:
#   niri-backdrop             # pone la imagen seteada (o la primera de la carpeta)
#   niri-backdrop set IMAGEN  # setea una imagen específica de ~/Pictures/Wallpaper
#   niri-backdrop stop        # detiene el fondo del backdrop
{ pkgs, lib }:

let
  wallpapersDir = "$HOME/Pictures/Wallpaper";
  stateFile = "$HOME/.config/mpvpaper/backdrop.txt";
in
pkgs.writeShellScriptBin "niri-backdrop" ''
  set -euo pipefail

  DIR="${wallpapersDir}"
  STATE="${stateFile}"
  SWAYBG="${pkgs.swaybg}/bin/swaybg"
  IMG=""

  stop_backdrop() {
    pkill -f '[s]waybg' 2>/dev/null || true
  }

  # Primera imagen disponible en la carpeta (png/jpg/jpeg/webp).
  pick_image() {
    find "$DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '%p\n' | sort | head -1
  }

  case "''${1:-}" in
    stop)
      stop_backdrop
      exit 0
      ;;
    set)
      NAME="''${2:-}"
      [ -z "$NAME" ] && { echo "Uso: niri-backdrop set IMAGEN" >&2; exit 1; }
      [ -f "$DIR/$NAME" ] || { echo "No existe: $NAME" >&2; exit 1; }
      mkdir -p "$(dirname "$STATE")"
      echo "$NAME" > "$STATE"
      IMG="$DIR/$NAME"
      ;;
    *)
      if [ -f "$STATE" ]; then
        NAME="$(cat "$STATE")"
        [ -f "$DIR/$NAME" ] && IMG="$DIR/$NAME" || IMG="$(pick_image)"
      else
        IMG="$(pick_image)"
      fi
      ;;
  esac

  [ -z "$IMG" ] && { echo "No hay imagen en $DIR" >&2; exit 1; }

  stop_backdrop
  # Desacoplado: sobrevive al shell que lo lanzó.
  setsid "$SWAYBG" -i "$IMG" -m fill >/dev/null 2>&1 &
''
