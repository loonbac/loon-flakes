# Controlador de Tailscale sobre el túnel SSH-over-TLS supervisado por systemd.
{ pkgs, stateHelper }:

pkgs.writeShellApplication {
  name = "ts-bypass";
  runtimeInputs = with pkgs; [
    coreutils
    curl
    gnugrep
    iproute2
    jq
    procps
    systemd
    tailscale
  ];
  text = ''
    set -euo pipefail

    readonly service="ts-bypass-tunnel.service"
    readonly derp_url="https://derp16b.tailscale.com/derp/latency-check"
    readonly peer="''${TS_BYPASS_PEER:-nixos-pc}"
    readonly sudo_cmd="/run/wrappers/bin/sudo"

    tunnel_ready() {
      curl --fail --silent --show-error --max-time 8 \
        --socks5-hostname 127.0.0.1:1080 \
        --output /dev/null "$derp_url"
    }

    wait_for_tunnel() {
      local _attempt
      for _attempt in $(seq 1 12); do
        if systemctl is-active --quiet "$service" && tunnel_ready; then
          return 0
        fi
        sleep 1
      done
      return 1
    }

    wait_for_peer() {
      local _attempt

      # El daemon entra en Running antes de terminar de recibir el netmap.
      # Darle margen evita declarar fallo durante ese calentamiento normal.
      sleep 5
      for _attempt in $(seq 1 4); do
        if tailscale ping --until-direct=false --c 1 --timeout 10s "$peer"; then
          return 0
        fi
        sleep 2
      done
      return 1
    }

    show_status() {
      local failed=0

      if systemctl is-active --quiet "$service"; then
        echo "Túnel systemd: activo"
      else
        echo "Túnel systemd: inactivo"
        failed=1
      fi

      if ss -ltn '( sport = :1080 )' | grep -q '127.0.0.1:1080'; then
        echo "SOCKS 127.0.0.1:1080: escuchando"
      else
        echo "SOCKS 127.0.0.1:1080: no disponible"
        failed=1
      fi

      if tunnel_ready; then
        echo "DERP por el VPS: accesible"
      else
        echo "DERP por el VPS: no accesible"
        failed=1
      fi

      if [[ -s /var/lib/ts-bypass/tailscaled.env ]]; then
        echo "Tailscale: configurado para usar ALL_PROXY"
      else
        echo "Tailscale: conexión directa"
      fi

      if systemctl show-environment | grep -Eq '^(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)='; then
        echo "Advertencia: quedan variables HTTP proxy incompatibles en systemd" >&2
        failed=1
      fi

      echo
      tailscale status || failed=1
      return "$failed"
    }

    enable_bypass() {
      echo "[1/4] Limpiando la configuración proxy incompatible anterior..."
      "$sudo_cmd" systemctl unset-environment \
        ALL_PROXY all_proxy HTTP_PROXY HTTPS_PROXY http_proxy https_proxy \
        NO_PROXY no_proxy

      echo "[2/4] Activando el túnel SSH-over-TLS supervisado..."
      "$sudo_cmd" ${stateHelper} enable

      # Migra limpiamente el proceso lanzado por la versión antigua del script.
      if ! systemctl is-active --quiet "$service" \
        && ss -ltn '( sport = :1080 )' | grep -q '127.0.0.1:1080'; then
        pkill -u "$USER" -f 'ssh .* -D (127\.0\.0\.1:)?1080 ' || true
      fi

      if ! "$sudo_cmd" systemctl start "$service"; then
        echo "systemd no pudo iniciar el túnel; revirtiendo el modo bypass." >&2
        "$sudo_cmd" ${stateHelper} disable
        "$sudo_cmd" systemctl stop "$service" || true
        systemctl --no-pager --full status "$service" >&2 || true
        exit 1
      fi

      if ! wait_for_tunnel; then
        echo "El túnel no logró alcanzar DERP; Tailscale permanece sin cambios." >&2
        "$sudo_cmd" ${stateHelper} disable
        "$sudo_cmd" systemctl stop "$service" || true
        systemctl --no-pager --full status "$service" >&2 || true
        exit 1
      fi

      echo "[3/4] Reiniciando Tailscale con ALL_PROXY (SOCKS5)..."
      "$sudo_cmd" systemctl restart tailscaled.service

      echo "[4/4] Verificando conectividad real con $peer..."
      if ! wait_for_peer; then
        echo "El túnel funciona, pero Tailscale no pudo alcanzar $peer." >&2
        echo "Últimos mensajes de tailscaled:" >&2
        journalctl -u tailscaled.service --since '-1 minute' --no-pager \
          | tail -n 25 >&2 || true
        exit 1
      fi

      echo "TS-Bypass activo y verificado con $peer."
    }

    disable_bypass() {
      echo "Restaurando la conexión directa de Tailscale..."
      "$sudo_cmd" ${stateHelper} disable
      "$sudo_cmd" systemctl unset-environment \
        ALL_PROXY all_proxy HTTP_PROXY HTTPS_PROXY http_proxy https_proxy \
        NO_PROXY no_proxy
      "$sudo_cmd" systemctl restart tailscaled.service
      "$sudo_cmd" systemctl stop "$service" || true
      echo "TS-Bypass desactivado."
      tailscale status
    }

    case "''${1:-}" in
      on|start)
        enable_bypass
        ;;
      off|stop)
        disable_bypass
        ;;
      restart)
        "$sudo_cmd" systemctl restart "$service"
        wait_for_tunnel
        "$sudo_cmd" systemctl restart tailscaled.service
        wait_for_peer
        ;;
      status)
        show_status
        ;;
      logs)
        journalctl -u "$service" -u tailscaled.service --no-pager -n 100
        ;;
      *)
        echo "Uso: ts-bypass {on|off|restart|status|logs}" >&2
        exit 2
        ;;
    esac
  '';
}
