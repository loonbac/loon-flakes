# Paquete "screen-brightness": gestor de brillo con escala remapeada (0% - 100%)
# donde el 0% equivale al 10% físico del hardware (evita que la pantalla se apague a oscuras).
{ pkgs, lib }:

pkgs.writeShellScriptBin "screen-brightness" ''
  set -euo pipefail

  # Si el sistema declara un wrapper setuid para brightnessctl hay que usarlo:
  # invocar el binario del store directamente termina en "Permission denied"
  # para el usuario. Ese wrapper vivía en hosts/loon-laptop/platform.nix y se
  # retiró el 2026-11-13 con ese host; mientras no exista, el fallback de
  # abajo es el camino que se ejecuta.
  BRIGHTNESSCTL="/run/wrappers/bin/brightnessctl"
  if [ ! -x "$BRIGHTNESSCTL" ]; then
    BRIGHTNESSCTL="${pkgs.brightnessctl}/bin/brightnessctl"
  fi

  CMD="''${1:-get}"
  SYS_DIR="/sys/class/backlight/intel_backlight"
  if [ ! -d "$SYS_DIR" ]; then
    # /sys/class/backlight contiene enlaces simbólicos a los dispositivos.
    # `find -type d` sin seguir enlaces no los detecta y hacía que Waybar
    # ocultara el brillo cuando el driver no se llamaba intel_backlight.
    SYS_DIR=""
    for candidate in /sys/class/backlight/*; do
      if [ -d "$candidate" ] && [ -f "$candidate/max_brightness" ]; then
        SYS_DIR="$candidate"
        break
      fi
    done
  fi

  if [ -z "$SYS_DIR" ] || [ ! -f "$SYS_DIR/max_brightness" ]; then
    # Un monitor externo de escritorio no expone /sys/class/backlight. Waybar
    # necesita una respuesta JSON válida para ocultar el módulo sin registrar
    # un error cada segundo; los comandos de control sí conservan el fallo.
    if [ "$CMD" = json ]; then
      echo '{"text":"", "percentage":0, "alt":"unavailable", "tooltip":"Brillo no disponible"}'
      exit 0
    fi
    echo "screen-brightness: No se encontró interfaz backlight en /sys/class/backlight." >&2
    exit 1
  fi

  MAX_RAW="$(cat "$SYS_DIR/max_brightness")"
  DEVICE="$(basename "$SYS_DIR")"
  # El 10% del hardware es el 0% de la escala de usuario
  MIN_RAW=$(( MAX_RAW / 10 ))
  SPAN_RAW=$(( MAX_RAW - MIN_RAW ))

  get_cur_raw() {
    cat "$SYS_DIR/brightness" 2>/dev/null || echo "$MIN_RAW"
  }

  raw_to_ui() {
    local cur="''${1:-$MIN_RAW}"
    if [ "$cur" -le "$MIN_RAW" ]; then
      echo "0"
      return
    fi
    if [ "$cur" -ge "$MAX_RAW" ]; then
      echo "100"
      return
    fi
    local diff=$(( cur - MIN_RAW ))
    local pct=$(( (diff * 100 + (SPAN_RAW / 2)) / SPAN_RAW ))
    if [ "$pct" -gt 100 ]; then pct=100; fi
    if [ "$pct" -lt 0 ]; then pct=0; fi
    echo "$pct"
  }

  ui_to_raw() {
    local ui_pct="''${1:-0}"
    if [ "$ui_pct" -le 0 ]; then
      echo "$MIN_RAW"
      return
    fi
    if [ "$ui_pct" -ge 100 ]; then
      echo "$MAX_RAW"
      return
    fi
    local added=$(( (ui_pct * SPAN_RAW + 50) / 100 ))
    local target=$(( MIN_RAW + added ))
    if [ "$target" -gt "$MAX_RAW" ]; then target="$MAX_RAW"; fi
    if [ "$target" -lt "$MIN_RAW" ]; then target="$MIN_RAW"; fi
    echo "$target"
  }

  notify_waybar() {
    pkill -RTMIN+8 waybar 2>/dev/null || true
  }

  case "$CMD" in
    get)
      CUR="$(get_cur_raw)"
      raw_to_ui "$CUR"
      ;;

    set)
      TARGET_UI="''${2:-0}"
      TARGET_UI="''${TARGET_UI%%%}"
      TARGET_RAW="$(ui_to_raw "$TARGET_UI")"
      "$BRIGHTNESSCTL" --device="$DEVICE" --min-value="$MIN_RAW" set "$TARGET_RAW" >/dev/null
      notify_waybar
      ;;

    up|+)
      STEP="''${2:-10}"
      STEP="''${STEP%%%}"
      STEP="''${STEP#+}"
      CUR_RAW="$(get_cur_raw)"
      CUR_UI="$(raw_to_ui "$CUR_RAW")"
      NEW_UI=$(( CUR_UI + STEP ))
      if [ "$NEW_UI" -gt 100 ]; then NEW_UI=100; fi
      TARGET_RAW="$(ui_to_raw "$NEW_UI")"
      "$BRIGHTNESSCTL" --device="$DEVICE" --min-value="$MIN_RAW" set "$TARGET_RAW" >/dev/null
      notify_waybar
      ;;

    down|-)
      STEP="''${2:-10}"
      STEP="''${STEP%%%}"
      STEP="''${STEP#-}"
      CUR_RAW="$(get_cur_raw)"
      CUR_UI="$(raw_to_ui "$CUR_RAW")"
      NEW_UI=$(( CUR_UI - STEP ))
      if [ "$NEW_UI" -lt 0 ]; then NEW_UI=0; fi
      TARGET_RAW="$(ui_to_raw "$NEW_UI")"
      "$BRIGHTNESSCTL" --device="$DEVICE" --min-value="$MIN_RAW" set "$TARGET_RAW" >/dev/null
      notify_waybar
      ;;

    json)
      CUR_RAW="$(get_cur_raw)"
      UI_PCT="$(raw_to_ui "$CUR_RAW")"
      
      if [ "$UI_PCT" -ge 65 ]; then
        ALT="high"
      elif [ "$UI_PCT" -ge 30 ]; then
        ALT="medium"
      else
        ALT="low"
      fi

      echo "{\"text\": \"$UI_PCT%\", \"percentage\": $UI_PCT, \"alt\": \"$ALT\", \"tooltip\": \"Brillo: $UI_PCT%\"}"
      ;;

    *)
      echo "Uso: screen-brightness [get|set <0..100>|up [step]|down [step]|json]" >&2
      exit 1
      ;;
  esac
''
