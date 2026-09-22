# Comando custom `rebuild`: reconstruye la configuración de NixOS
# del host actual usando el flake local (~/.nixos).
# Equivalente al "cargo build && cargo run" del proyecto.
#
# Uso:
#   rebuild            # aplica los cambios (nixos-rebuild switch; sobre SSH se aplica desacoplado)
#   rebuild dry        # prueba sin aplicar
#   rebuild update     # actualiza y prepara el próximo arranque con boot (conserva boot sin switch)
{ pkgs, lib }:

let
  script = pkgs.writeShellScriptBin "rebuild" ''
    set -euo pipefail

    FLAKE_DIR="$HOME/.nixos"
    HOST="''${NIXOS_HOST:-$(< /proc/sys/kernel/hostname)}"

    cd "$FLAKE_DIR"

    case "$HOST" in
      ""|*[!A-Za-z0-9_-]*)
        echo "Hostname no válido para seleccionar el flake: '$HOST'" >&2
        exit 1
        ;;
    esac

    configured_host="$(${pkgs.nix}/bin/nix eval --raw \
      "$FLAKE_DIR#nixosConfigurations.$HOST.config.networking.hostName" 2>/dev/null)" || {
      echo "El flake no contiene nixosConfigurations.$HOST" >&2
      exit 1
    }
    if [[ "$configured_host" != "$HOST" ]]; then
      echo "La configuración '$HOST' declara el hostname '$configured_host'." >&2
      exit 1
    fi

    case "''${1:-switch}" in
      dry)
        sudo nixos-rebuild dry-run --flake ".#$HOST"
        ;;
      update)
        nix flake update
        # Una actualización de inputs puede cambiar componentes fundamentales
        # (greetd, PAM, systemd, drivers...). Aplicarlos con `switch` mientras
        # hay una sesión gráfica activa puede quitarle el seat/DRM a niri y
        # dejar un compositor viejo vivo, provocando un bucle de login.
        # `boot` instala y firma la generación sin tocar la sesión actual.
        sudo nixos-rebuild boot --flake ".#$HOST"
        echo
        echo "Actualización preparada de forma segura."
        echo "La sesión actual no fue reiniciada; reinicia cuando quieras aplicarla."
        ;;
      switch)
        # `nixos-rebuild switch` ejecuta `switch-to-configuration` a través de
        # `systemd-run --pipe`. Si el comando corre por SSH y la conexión cae,
        # systemd cancela la activación a mitad de camino y puede dejar servicios
        # críticos detenidos (como ocurrió con NetworkManager el 2026-09-22).
        # Para evitarlo, sobre SSH desacoplamos la activación en una unidad transitoria
        # propia de systemd y seguimos su log con journalctl. Si la sesión SSH muere,
        # el seguimiento termina pero la unidad sigue corriendo hasta completarse.
        if [[ -n "''${SSH_CONNECTION:-}" ]]; then
          sudo -v
          unit="loon-rebuild-$(date +%s)"
          echo "Ejecutando switch desacoplado en la unidad systemd '$unit'..."
          echo "Si la conexión SSH se interrumpe, la activación continuará sin detenerse."
          echo "Para seguir los registros más tarde: sudo journalctl -u $unit -f"
          echo
          sudo systemd-run \
            --unit="$unit" \
            --collect \
            --no-block \
            --property=Type=oneshot \
            --property=WorkingDirectory="$FLAKE_DIR" \
            --property=Environment=PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin \
            /run/current-system/sw/bin/nixos-rebuild switch --flake ".#$HOST"
          sudo journalctl -u "$unit" -f --no-pager || true
        else
          sudo nixos-rebuild switch --flake ".#$HOST"
        fi
        ;;
      *)
        echo "Uso: rebuild [switch|dry|update]" >&2
        exit 1
        ;;
    esac
  '';
in
script
