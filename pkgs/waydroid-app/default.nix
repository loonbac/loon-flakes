# Paquete "waydroid-app": lanza una app de Android desde el launcher sin fricción.
#
# "Abrir TikTok" debe funcionar de una, como cualquier app nativa. Waydroid tiene
# dos capas que pueden estar caídas: el contenedor (servicio systemd) y la sesión
# gráfica (solo corre cuando hay una ventana). Este wrapper las levanta bajo
# demanda y luego lanza la app:
#
#   waydroid-app com.zhiliaoapp.musically   # TikTok
#
# Requisitos:
#   - El usuario puede controlar waydroid-container sin sudo vía polkit
#     (regla en modules/programs/waydroid/default.nix).
#   - El contenedor debe estar inicializado (waydroid init ya hecho).
{ pkgs, lib }:

pkgs.writeShellScriptBin "waydroid-app" ''
  set -eu

  PKG=''${1:-}
  if [ -z "$PKG" ]; then
    echo "uso: waydroid-app <package.android.app>" >&2
    exit 1
  fi

  WAYDROID="${pkgs.waydroid-nftables}/bin/waydroid"
  SLEEP="${pkgs.coreutils}/bin/sleep"

  # 1. Contenedor: si el servicio no está activo, arrancarlo.
  if ! systemctl is-active --quiet waydroid-container; then
    systemctl start waydroid-container
    for _ in $(seq 1 30); do
      systemctl is-active --quiet waydroid-container && break
      "$SLEEP" 1
    done
  fi

  # 2. Sesión gráfica: si no hay sesión corriendo, levantarla desacoplada.
  if ! "$WAYDROID" status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    # Desacoplar por completo: nohup + setsid para que no muera con el wrapper
    # ni herede su stdin (que colgaba el script esperando EOF).
    setsid nohup "$WAYDROID" session start >/dev/null 2>&1 < /dev/null &
    # Esperar a que Android bootee, con tope duro de 90s.
    for _ in $(seq 1 90); do
      if "$WAYDROID" status 2>/dev/null | grep -q "Session:.*RUNNING"; then
        break
      fi
      "$SLEEP" 1
    done
  fi

  # 3. Lanzar la app.
  exec "$WAYDROID" app launch "$PKG"
''
