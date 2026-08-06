# Comando custom `rebuild`: reconstruye la configuración de NixOS
# del host loon-laptop usando el flake local (~/.nixos).
# Equivalente al "cargo build && cargo run" del proyecto.
#
# Uso:
#   rebuild            # aplica los cambios (nixos-rebuild switch)
#   rebuild dry        # prueba sin aplicar
#   rebuild update     # actualiza nixpkgs y aplica
{ pkgs, lib }:

let
  script = pkgs.writeShellScriptBin "rebuild" ''
    set -euo pipefail

    FLAKE_DIR="$HOME/.nixos"
    HOST="loon-laptop"

    cd "$FLAKE_DIR"

    case "''${1:-switch}" in
      dry)
        sudo nixos-rebuild dry-run --flake ".#$HOST"
        ;;
      update)
        nix flake update
        sudo nixos-rebuild switch --flake ".#$HOST"
        ;;
      switch)
        sudo nixos-rebuild switch --flake ".#$HOST"
        ;;
      *)
        echo "Uso: rebuild [switch|dry|update]" >&2
        exit 1
        ;;
    esac
  '';
in
script
