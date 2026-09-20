# Script "mpvpaper-wallpaper": fondo de pantalla animado con mpvpaper.
# Detecta cualquier video en ~/Videos/Wallpapers y permite setearlo.
#
# Uso:
#   mpvpaper-wallpaper            # reproduce el video seteado (o el único/primero)
#   mpvpaper-wallpaper set NOMBRE # setea y reproduce un video específico
#   mpvpaper-wallpaper list       # lista los videos disponibles
#   mpvpaper-wallpaper pause [MOTIVO]  # pausa por IPC conservando el último frame
#   mpvpaper-wallpaper resume [MOTIVO] # retira ese motivo; reanuda si no quedan otros
#   mpvpaper-wallpaper status     # muestra playing, paused o stopped
#   mpvpaper-wallpaper stop       # detiene el fondo animado
{ pkgs, lib, accent-wallpaper }:

let
  wallpapersDir = "$HOME/Videos/Wallpapers";
  stateFile = "$HOME/.config/mpvpaper/current.txt";
  # 1.9 corrige la fuga de fences OpenGL con libmpv 0.41 (#132).
  mpvpaperFixed = pkgs.callPackage ../mpvpaper-fixed { };
in
pkgs.writeShellScriptBin "mpvpaper-wallpaper" ''
  set -euo pipefail

  DIR="${wallpapersDir}"
  STATE="${stateFile}"
  MPVPAPER="${mpvpaperFixed}/bin/mpvpaper"
  RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
  IPC_DIR="$RUNTIME_DIR/mpvpaper-wallpaper"
  IPC="$IPC_DIR/mpv.sock"
  CHANGE_LOCK="$IPC_DIR/change.lock"
  PAUSE_DIR="$IPC_DIR/paused.d"
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

  validate_pause_reason() {
    case "$1" in
      ""|*[!A-Za-z0-9._-]*)
        echo "mpvpaper-wallpaper: motivo de pausa inválido: $1" >&2
        return 1
        ;;
    esac
  }

  query_paused() {
    local response
    [ -S "$IPC" ] || return 1
    response="$(send_ipc_to "$IPC" '{"command":["get_property","pause"]}' || true)"
    case "$response" in
      *'"data":true'*) return 0 ;;
      *) return 1 ;;
    esac
  }

  has_pause_reasons() {
    local marker
    [ -d "$PAUSE_DIR" ] || return 1
    for marker in "$PAUSE_DIR"/*; do
      [ -f "$marker" ] && return 0
    done
    return 1
  }

  pause_for() {
    local reason=$1
    validate_pause_reason "$reason"
    ensure_runtime_dir
    mkdir -p "$PAUSE_DIR"

    # Si otro componente pausó directamente una instancia iniciada con una
    # versión anterior del script, preservar esa pausa como manual antes de
    # adquirir nuestro motivo propio.
    if [ "$reason" != manual ] && ! has_pause_reasons && query_paused; then
      : > "$PAUSE_DIR/manual"
    fi

    : > "$PAUSE_DIR/$reason"
    send_ipc '{"command":["set_property","pause",true]}' >/dev/null
  }

  resume_for() {
    local reason=$1
    local marker="$PAUSE_DIR/$reason"
    validate_pause_reason "$reason"

    # No tocar el estado de reproducción si este actor nunca adquirió la
    # pausa. Así un watcher recién iniciado no deshace una pausa ajena.
    [ -f "$marker" ] || return 0
    rm -f "$marker"
    if ! has_pause_reasons; then
      send_ipc '{"command":["set_property","pause",false]}' >/dev/null
    fi
  }

  apply_pause_reasons() {
    local socket=$1
    if has_pause_reasons; then
      send_ipc_to "$socket" '{"command":["set_property","pause",true]}' >/dev/null || true
    fi
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

  prepare_accent() {
    local video=$1
    # Publicar la paleta antes de crear la superficie que hará el fade. En
    # selecciones repetidas accent-wallpaper responde desde su caché.
    if "${accent-wallpaper}/bin/accent-wallpaper" from "$video" >/dev/null 2>&1; then
      # Dar un frame al monitor CSS de Waybar sin reiniciar la barra.
      ${pkgs.coreutils}/bin/sleep 0.05
      return 0
    fi
    echo "mpvpaper-wallpaper: no se pudo preparar la paleta; se conserva la anterior" >&2
    return 1
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
    apply_pause_reasons "$IPC"
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
      pause_for "''${2:-manual}"
      exit 0
      ;;
    resume)
      resume_for "''${2:-manual}"
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
      OLD_VIDEO=""
      if [ -f "$STATE" ]; then
        OLD_NAME="$(cat "$STATE")"
        [ -f "$DIR/$OLD_NAME" ] && OLD_VIDEO="$DIR/$OLD_NAME"
      fi
      ensure_state_dir
      prepare_accent "$VIDEO" || true
      if transition_wallpaper "$VIDEO"; then
        echo "$NAME" > "$STATE"
      else
        # Si el video nuevo no carga, conservar tanto el state como los colores
        # del wallpaper que sigue visible.
        [ -z "$OLD_VIDEO" ] || prepare_accent "$OLD_VIDEO" || true
        exit 1
      fi
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

      prepare_accent "$VIDEO" || true
      stop_wallpaper
      # Desacoplado del shell padre: sobrevive a la sesión que lo lanzó.
      start_wallpaper "$VIDEO" "$IPC" none
      if wait_for_video "$IPC"; then
        apply_pause_reasons "$IPC"
      fi
      ;;
  esac
''
