# Paquete "battery-notify": daemon ligero que vigila el nivel de batería y emite
# alertas periódicas críticas cada 1 minuto cuando la batería baja al 10% o menos.
{ pkgs, lib }:

pkgs.writeShellScriptBin "battery-notify" ''
  set -eu

  NOTIFY_SEND="${pkgs.libnotify}/bin/notify-send"
  INTERVAL=15
  CRITICAL_THRESHOLD=10
  NOTIFY_INTERVAL=60

  LAST_NOTIFIED=0
  WAS_CRITICAL=0

  get_battery_path() {
    for b in /sys/class/power_supply/BAT* /sys/class/power_supply/battery; do
      if [ -d "$b" ]; then
        echo "$b"
        return 0
      fi
    done
    return 1
  }

  BAT_PATH="$(get_battery_path || true)"
  if [ -z "$BAT_PATH" ]; then
    echo "battery-notify: No se encontró interfaz de batería en /sys/class/power_supply/." >&2
    exit 0
  fi

  while true; do
    if [ -f "$BAT_PATH/capacity" ] && [ -f "$BAT_PATH/status" ]; then
      CAPACITY="$(cat "$BAT_PATH/capacity" 2>/dev/null || echo 100)"
      STATUS="$(cat "$BAT_PATH/status" 2>/dev/null || echo "Unknown")"
      NOW="$(date +%s)"

      # Si está descargando y el porcentaje es <= 10%
      if [ "$STATUS" = "Discharging" ] || [ "$STATUS" = "Not charging" ]; then
        if [ "$CAPACITY" -le "$CRITICAL_THRESHOLD" ]; then
          ELAPSED=$((NOW - LAST_NOTIFIED))
          if [ "$ELAPSED" -ge "$NOTIFY_INTERVAL" ] || [ "$LAST_NOTIFIED" -eq 0 ]; then
            "$NOTIFY_SEND" \
              -u critical \
              -a "Alerta de Batería" \
              -i "battery-empty" \
              -t 55000 \
              "🚨 ¡BATERÍA CRÍTICA (''${CAPACITY}%)! 🚨" \
              "¡Conecta el cargador AHORA MISMO antes de que se apague el equipo!"

            LAST_NOTIFIED="$NOW"
            WAS_CRITICAL=1
          fi
        else
          # Si la batería está por encima del umbral crítico, reseteamos el temporizador
          LAST_NOTIFIED=0
          WAS_CRITICAL=0
        fi
      elif [ "$STATUS" = "Charging" ]; then
        if [ "$WAS_CRITICAL" -eq 1 ]; then
          "$NOTIFY_SEND" \
            -u normal \
            -a "Alerta de Batería" \
            -i "battery-charging" \
            -t 5000 \
            "🔌 Cargador conectado" \
            "Cargando batería (''${CAPACITY}%)."
          WAS_CRITICAL=0
        fi
        LAST_NOTIFIED=0
      fi
    fi

    sleep "$INTERVAL"
  done
''
