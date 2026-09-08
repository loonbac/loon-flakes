# Script "mpvpaper-wallpaper": fondo de pantalla animado con mpvpaper.
# Detecta cualquier video en ~/Videos/Wallpapers y permite setearlo.
#
# Uso:
#   mpvpaper-wallpaper            # reproduce el video seteado (o el único/primero)
#   mpvpaper-wallpaper set NOMBRE # setea y reproduce un video específico
#   mpvpaper-wallpaper list       # lista los videos disponibles
#   mpvpaper-wallpaper pause      # pausa por IPC conservando el último frame
#   mpvpaper-wallpaper resume     # reanuda el mismo proceso/video por IPC
#   mpvpaper-wallpaper status     # muestra playing, paused o stopped
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
  RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
  IPC_DIR="$RUNTIME_DIR/mpvpaper-wallpaper"
  IPC="$IPC_DIR/mpv.sock"
  CHANGE_LOCK="$IPC_DIR/change.lock"
  FADE_DURATION="0.8"

  ensure_state_dir() {
    mkdir -p "$(dirname "$STATE")"
  }

  ensure_runtime_dir() {
    mkdir -p "$IPC_DIR"
    chmod 700 "$IPC_DIR"
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
    rm -f "$IPC" "$IPC".next-*
  }

  start_wallpaper() {
    local video=$1
    local socket=$2
    local transition=$3
    local transition_graph
    local flags
    ensure_runtime_dir
    rm -f "$socket"
    # mpvpaper reenvía estas opciones a la instancia libmpv que renderiza el
    # wallpaper. El socket queda en el runtime privado del usuario, nunca en
    # /tmp, y permite pausar sin destruir la superficie layer-shell.
    flags="no-audio --loop-file=inf --panscan=1 --profile=fast --no-cache --osc=no --input-ipc-server=$socket"
    if [ "$transition" = fade ]; then
      # El proceso nuevo se compone sobre el anterior. El filtro genera alpha
      # y hace un fade-in desde transparente; al terminar se elimina para no
      # mantener el coste del filtro durante toda la reproducción.
      transition_graph="format=rgba,split=2[clear][live];[clear]lutrgb=a=0[transparent];[transparent][live]xfade=transition=fade:duration=$FADE_DURATION:offset=0"
      flags="$flags --background=none --vf=lavfi=[$transition_graph]"
    fi
    setsid "$MPVPAPER" -o "$flags" ALL "$video" >/dev/null 2>&1 &
    STARTED_PID=$!
  }

  send_ipc_to() {
    local socket=$1
    local payload=$2
    printf '%s\n' "$payload" \
      | ${pkgs.socat}/bin/socat -T 1 - "UNIX-CONNECT:$socket" 2>/dev/null
  }

  send_ipc() {
    local payload=$1
    if [ ! -S "$IPC" ]; then
      echo "mpvpaper-wallpaper: no hay socket IPC activo" >&2
      return 0
    fi
    # Ausencia/cierre del proceso es inocuo para los perfiles de energía.
    send_ipc_to "$IPC" "$payload" || true
  }

  wait_for_video() {
    local socket=$1
    local response
    local attempt
    for attempt in $(seq 1 100); do
      if [ -S "$socket" ]; then
        response="$(send_ipc_to "$socket" '{"command":["get_property","video-out-params"]}' || true)"
        case "$response" in
          *'"data":{'*) return 0 ;;
        esac
      fi
      sleep 0.05
    done
    return 1
  }

  stop_pids() {
    local pid
    local attempt
    for pid in "$@"; do
      kill "$pid" 2>/dev/null || true
    done
    for attempt in $(seq 1 20); do
      local alive=false
      for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
          alive=true
          break
        fi
      done
      [ "$alive" = false ] && return 0
      sleep 0.05
    done
    for pid in "$@"; do
      kill -KILL "$pid" 2>/dev/null || true
    done
  }

  transition_wallpaper() {
    local video=$1
    local next_ipc="$IPC.next.$$"
    local old_pids

    old_pids="$(${pkgs.procps}/bin/pgrep -f '[b]in/mpvpaper ' || true)"
    start_wallpaper "$video" "$next_ipc" fade

    # No se toca el wallpaper anterior hasta tener el primer frame nuevo.
    if ! wait_for_video "$next_ipc"; then
      kill "$STARTED_PID" 2>/dev/null || true
      rm -f "$next_ipc"
      echo "mpvpaper-wallpaper: el wallpaper nuevo no llegó a cargar" >&2
      return 1
    fi

    # El tiempo del filtro comienza con el primer frame decodificado.
    sleep "$FADE_DURATION"
    [ -z "$old_pids" ] || stop_pids $old_pids

    # Conserva la ruta IPC pública usada por pause/resume/status y elimina el
    # filtro temporal una vez que el video nuevo ya cubre al anterior.
    rm -f "$IPC"
    mv "$next_ipc" "$IPC"
    send_ipc_to "$IPC" '{"command":["set_property","vf",""]}' >/dev/null || true
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
    pause)
      send_ipc '{"command":["set_property","pause",true]}' >/dev/null
      exit 0
      ;;
    resume)
      send_ipc '{"command":["set_property","pause",false]}' >/dev/null
      exit 0
      ;;
    status)
      if [ ! -S "$IPC" ]; then
        echo stopped
      else
        RESPONSE="$(send_ipc '{"command":["get_property","pause"]}')"
        case "$RESPONSE" in
          *'"data":true'*) echo paused ;;
          *'"data":false'*) echo playing ;;
          *) echo unavailable ;;
        esac
      fi
      exit 0
      ;;
    list)
      list_videos
      exit 0
      ;;
    set)
      ensure_runtime_dir
      # Serializa clicks rápidos del selector sin heredar el lock al proceso
      # persistente de mpvpaper.
      if [ "''${MPVPAPER_WALLPAPER_LOCKED:-0}" != 1 ]; then
        exec ${pkgs.util-linux}/bin/flock --close "$CHANGE_LOCK" \
          ${pkgs.coreutils}/bin/env MPVPAPER_WALLPAPER_LOCKED=1 "$0" "$@"
      fi
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
      transition_wallpaper "$VIDEO"
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
      start_wallpaper "$VIDEO" "$IPC" none
      # Extrae el color de acento del video nuevo (desacoplado, async).
      setsid "${accent-wallpaper}/bin/accent-wallpaper" from "$VIDEO" >/dev/null 2>&1 &
      ;;
  esac
''
