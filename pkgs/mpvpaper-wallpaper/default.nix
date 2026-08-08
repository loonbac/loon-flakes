# Script "mpvpaper-wallpaper": fondo de pantalla animado con mpvpaper.
# Detecta cualquier video en ~/Videos/Wallpapers y permite setearlo.
#
# Uso:
#   mpvpaper-wallpaper            # reproduce el video seteado (o el único/primero)
#   mpvpaper-wallpaper set NOMBRE # setea y reproduce un video específico
#   mpvpaper-wallpaper list       # lista los videos disponibles
#   mpvpaper-wallpaper stop       # detiene el fondo animado
{ pkgs, lib, accent-wallpaper }:

let
  wallpapersDir = "$HOME/Videos/Wallpapers";
  stateFile = "$HOME/.config/mpvpaper/current.txt";
in
pkgs.writeShellScriptBin "mpvpaper-wallpaper" ''
  set -euo pipefail

  DIR="${wallpapersDir}"
  STATE="${stateFile}"
  MPVPAPER="${pkgs.mpvpaper}/bin/mpvpaper"
  MPV_FLAGS="no-audio --loop-file=inf --profile=fast --no-cache --osc=no"

  ensure_state_dir() {
    mkdir -p "$(dirname "$STATE")"
  }

  # Matar cualquier instancia de mpvpaper en ejecución.
  # OJO 1: el proceso real se renombra a ".mpvpaper-wrapp", así que
  #   pkill -x 'mpvpaper' NO lo encuentra.
  # OJO 2: pkill -f matchea su PROPIA línea de comando y también la de este
  #   script: su ruta termina en ".../bin/mpvpaper-wallpaper", que contiene
  #   "bin/mpvpaper". Por eso usamos el patrón "bin/mpvpaper " (con espacio al
  #   final): el proceso real es "/nix/store/.../bin/mpvpaper -o ..." y termina
  #   con espacio, mientras que "mpvpaper-wallpaper" NO tiene espacio tras
  #   "mpvpaper". El bracket [b] evita que pkill se mate a sí mismo.
  stop_wallpaper() {
    pkill -f '[b]in/mpvpaper ' 2>/dev/null || true
  }

  list_videos() {
    # Busca videos en la carpeta (mp4, webm, mkv, gif, etc.) por orden alfabético.
    find "$DIR" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.gif' \) -printf '%f\n' | sort
  }

  case "''${1:-}" in
    stop)
      stop_wallpaper
      exit 0
      ;;
    list)
      list_videos
      exit 0
      ;;
    set)
      NAME="''${2:-}"
      if [ -z "$NAME" ]; then
        echo "Uso: mpvpaper-wallpaper set NOMBRE" >&2
        exit 1
      fi
      VIDEO="$DIR/$NAME"
      if [ ! -f "$VIDEO" ]; then
        echo "No existe el video: $NAME" >&2
        exit 1
      fi
      ensure_state_dir
      echo "$NAME" > "$STATE"
      stop_wallpaper
      # Desacoplado del shell padre: sobrevive a la sesión que lo lanzó
      # (importante para el bind de niri, que muere al cerrarse el terminal).
      setsid "$MPVPAPER" -o "$MPV_FLAGS" ALL "$VIDEO" >/dev/null 2>&1 &
      # Extrae el color de acento del video nuevo (desacoplado, async).
      setsid "${accent-wallpaper}/bin/accent-wallpaper" from "$VIDEO" >/dev/null 2>&1 &
      ;;
    *)
      # Sin argumentos: usa el seteado, o el único/primero si no hay state.
      VIDEOS="$(list_videos)"
      if [ -z "$VIDEOS" ]; then
        echo "No hay videos en $DIR" >&2
        exit 1
      fi

      if [ -f "$STATE" ]; then
        NAME="$(cat "$STATE")"
        if [ -f "$DIR/$NAME" ]; then
          VIDEO="$DIR/$NAME"
        else
          # El video seteado ya no existe: cae al primero disponible.
          VIDEO="$DIR/$(echo "$VIDEOS" | head -1)"
        fi
      else
        VIDEO="$DIR/$(echo "$VIDEOS" | head -1)"
      fi

      stop_wallpaper
      # Desacoplado del shell padre: sobrevive a la sesión que lo lanzó.
      setsid "$MPVPAPER" -o "$MPV_FLAGS" ALL "$VIDEO" >/dev/null 2>&1 &
      # Extrae el color de acento del video nuevo (desacoplado, async).
      setsid "${accent-wallpaper}/bin/accent-wallpaper" from "$VIDEO" >/dev/null 2>&1 &
      ;;
  esac
''
