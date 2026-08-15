# Paquete "screen-brightness": gestor de brillo con escala remapeada (0% - 100%)
# donde el 0% equivale al 10% físico del hardware (evita que la pantalla se apague a oscuras).
{ pkgs, lib }:

pkgs.writeShellScriptBin "screen-brightness" ''
  set -euo pipefail

  BRIGHTNESSCTL="${pkgs.brightnessctl}/bin/brightnessctl"
  SYS_DIR="/sys/class/backlight/intel_backlight"
  if [ ! -d "$SYS_DIR" ]; then
    SYS_DIR="$(find /sys/class/backlight -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
  fi

  if [ -z "$SYS_DIR" ] || [ ! -f "$SYS_DIR/max_brightness" ]; then
    echo "screen-brightness: No se encontró interfaz backlight en /sys/class/backlight." >&2
    exit 1
  fi

  MAX_RAW="$(cat "$SYS_DIR/max_brightness")"
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

  CMD="''${1:-get}"

  case "$CMD" in
    get)
      CUR="$(get_cur_raw)"
      raw_to_ui "$CUR"
      ;;

    set)
      TARGET_UI="''${2:-0}"
      TARGET_UI="''${TARGET_UI%%%}"
      TARGET_RAW="$(ui_to_raw "$TARGET_UI")"
      "$BRIGHTNESSCTL" --min-value="$MIN_RAW" set "$TARGET_RAW" >/dev/null 2>&1 || true
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
      "$BRIGHTNESSCTL" --min-value="$MIN_RAW" set "$TARGET_RAW" >/dev/null 2>&1 || true
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
      "$BRIGHTNESSCTL" --min-value="$MIN_RAW" set "$TARGET_RAW" >/dev/null 2>&1 || true
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
