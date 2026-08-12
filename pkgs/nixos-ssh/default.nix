# Comando custom `nixos-ssh`: toggle de autenticación del servidor SSH.
#
# Pregunta si se quiere autenticar por contraseña o por clave (cert),
# escribe el modo en modules/services/openssh/ssh-auth-mode y aplica la
# configuración NixOS con el mismo nixos-rebuild que el comando `rebuild`.
#
# Uso:
#   nixos-ssh      # menú interactivo: password | cert | cancelar
{ pkgs, lib }:

let
  script = pkgs.writeShellScriptBin "nixos-ssh" ''
    set -euo pipefail

    FLAKE_DIR="$HOME/.nixos"
    HOST="loon-laptop"
    STATE_FILE="$FLAKE_DIR/modules/services/openssh/ssh-auth-mode"

    # Si no existe el archivo de estado, lo crea con el modo seguro (cert).
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No se encontró ssh-auth-mode; creando con modo 'cert' (seguro)." >&2
      echo "cert" > "$STATE_FILE"
    fi

    current="$(cat "$STATE_FILE" | tr -d '[:space:]')"
    echo "Servidor SSH: loon-laptop ($HOST)"
    echo "Modo actual:  $current"
    echo

    PS3="Modo de autenticación SSH (1=password, 2=cert, 3=cancelar): "
    select mode in password cert cancelar; do
      case "$mode" in
        password|cert) break ;;
        cancelar) echo "Sin cambios."; exit 0 ;;
        *) echo "Opción inválida." ;;
      esac
    done

    if [[ "$mode" == "$current" ]]; then
      echo "El servidor ya está en modo '$mode'. Sin cambios."
      exit 0
    fi

    echo "$mode" > "$STATE_FILE"
    echo "Aplicando modo '$mode' al flake ($FLAKE_DIR)..."

    if ! (cd "$FLAKE_DIR" && sudo nixos-rebuild switch --flake ".#$HOST"); then
      echo "$current" > "$STATE_FILE"
      echo "El rebuild falló; se revirtió el modo a '$current'." >&2
      exit 1
    fi

    echo
    echo "SSH ahora en modo '$mode'."
    if [[ "$mode" == "password" ]]; then
      echo "Admitirá contraseña. (PermitRootLogin sigue en 'no'.)"
    else
      echo "Solo por clave/certificado (contraseñas desactivadas)."
    fi
  '';
in
script