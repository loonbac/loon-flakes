# Script "niri-backdrop": fondo estático en el backdrop de niri.
# El backdrop es la capa global que se ve detrás de todo (entre workspaces,
# en el overview y a través de ventanas transparentes con xray).
# Atrás del video animado de cada workspace, este pone una imagen fija.
#
# Usa awww (en vez de swaybg) para tener transiciones animadas al
# cambiar: fade, wipe, circle, grow, etc. El daemon corre con namespace
# "wallpaper" para que el layer-rule de niri (place-within-backdrop) lo
# mueva al backdrop. OJO: en nixpkgs 26.05 el paquete expone binarios
# "awww"/"awww-daemon" (fork de swww).
#
# Uso:
#   niri-backdrop                  # pone la imagen seteada (o la primera de la carpeta)
#   niri-backdrop set IMAGEN       # setea una imagen específica de ~/Pictures/Wallpaper
#   niri-backdrop pick             # abre fuzzel para elegir el fondo (con transición)
#   niri-backdrop next             # siguiente imagen de la carpeta (cíclico)
#   niri-backdrop stop             # detiene el fondo del backdrop
{ pkgs, lib, accent-wallpaper }:

let
  wallpapersDir = "$HOME/Pictures/Wallpaper";
  stateFile = "$HOME/.config/mpvpaper/backdrop.txt";
in
pkgs.writeShellScriptBin "niri-backdrop" ''
  set -euo pipefail

  DIR="${wallpapersDir}"
  VIDEO_DIR="$HOME/Videos/Wallpapers"
  STATE="${stateFile}"
  AWWW="${pkgs.awww}/bin/awww"
  AWWW_DAEMON="${pkgs.awww}/bin/awww-daemon"
  FUZZEL="${pkgs.fuzzel}/bin/fuzzel"
  ACCENT_WALLPAPER="${accent-wallpaper}/bin/accent-wallpaper"
  IMG=""
  GENERATE_ACCENT=false

  # Imagen actual seteada (del state) o la primera disponible.
  pick_image() {
    find "$DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '%f\n' | sort | head -1
  }

  # Lista de imágenes disponibles (nombres, ordenadas).
  list_images() {
    find "$DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '%f\n' | sort
  }

  # Al iniciar, mpvpaper es el único escritor de la paleta si hay video.
  # Las selecciones explícitas de imagen sí cambian el acento inmediatamente.
  has_video() {
    find "$VIDEO_DIR" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.gif' \) -print -quit 2>/dev/null | grep -q .
  }

  # Levanta el daemon de awww con namespace "wallpaper" si no está corriendo.
  ensure_daemon() {
    if ! "$AWWW" query --namespace wallpaper >/dev/null 2>&1; then
      setsid "$AWWW_DAEMON" --namespace wallpaper >/dev/null 2>&1 &
      # Espera a que el socket exista (máx ~2s).
      for _ in $(seq 1 20); do
        "$AWWW" query --namespace wallpaper >/dev/null 2>&1 && break
        sleep 0.1
      done
    fi
  }

  # Aplica la imagen con transición animada (fade suave).
  apply_wallpaper() {
    ensure_daemon
    if [ "$GENERATE_ACCENT" = true ]; then
      # Preparar y publicar la paleta antes del primer frame del fade evita que
      # Waybar cambie de color cuando la transición ya terminó. La caché de
      # accent-wallpaper hace que selecciones repetidas sean casi instantáneas.
      if "$ACCENT_WALLPAPER" from "$IMG" >/dev/null 2>&1; then
        # Dar un frame al monitor CSS de Waybar sin reiniciar la barra.
        ${pkgs.coreutils}/bin/sleep 0.05
      else
        echo "niri-backdrop: no se pudo preparar la paleta; se conserva la anterior" >&2
      fi
    fi
    "$AWWW" img --namespace wallpaper --transition-type fade --transition-duration 1.5 \
      --resize fit "$IMG" >/dev/null 2>&1 || true
  }

  stop_backdrop() {
    "$AWWW" kill --namespace wallpaper >/dev/null 2>&1 || true
  }

  case "''${1:-}" in
    stop)
      stop_backdrop
      exit 0
      ;;
    pick)
      NAME="$("$FUZZEL" --dmenu --placeholder "Elige un fondo..." <<< "$(list_images)")"
      [ -z "$NAME" ] && exit 0
      [ -f "$DIR/$NAME" ] || { echo "No existe: $NAME" >&2; exit 1; }
      mkdir -p "$(dirname "$STATE")"
      echo "$NAME" > "$STATE"
      IMG="$DIR/$NAME"
      GENERATE_ACCENT=true
      ;;
    next)
      CURRENT="$(cat "$STATE" 2>/dev/null || true)"
      NAME="$(list_images | awk -v cur="$CURRENT" 'BEGIN{found=0} {a[NR]=$0} END{ for(i=1;i<=NR;i++){ if(a[i]==cur){ if(i<NR){print a[i+1]} else {print a[1]}; found=1; break } } if(!found && NR>0) print a[1] }')"
      [ -z "$NAME" ] && { echo "No hay imágenes en $DIR" >&2; exit 1; }
      mkdir -p "$(dirname "$STATE")"
      echo "$NAME" > "$STATE"
      IMG="$DIR/$NAME"
      GENERATE_ACCENT=true
      ;;
    set)
      NAME="''${2:-}"
      [ -z "$NAME" ] && { echo "Uso: niri-backdrop set IMAGEN" >&2; exit 1; }
      [ -f "$DIR/$NAME" ] || { echo "No existe: $NAME" >&2; exit 1; }
      mkdir -p "$(dirname "$STATE")"
      echo "$NAME" > "$STATE"
      IMG="$DIR/$NAME"
      GENERATE_ACCENT=true
      ;;
    *)
      if [ -f "$STATE" ]; then
        NAME="$(cat "$STATE")"
        [ -f "$DIR/$NAME" ] && IMG="$DIR/$NAME" || IMG="$(pick_image)"
      else
        IMG="$(pick_image)"
      fi
      has_video || GENERATE_ACCENT=true
      ;;
  esac

  [ -z "$IMG" ] && { echo "No hay imagen en $DIR" >&2; exit 1; }

  apply_wallpaper
''
