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
{ pkgs, lib, waydroid ? pkgs.waydroid-nftables }:

pkgs.writeShellScriptBin "waydroid-app" ''
  set -eu

  PKG=''${1:-}
  if [ -z "$PKG" ]; then
    echo "uso: waydroid-app <package.android.app>" >&2
    exit 1
  fi

  export WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-wayland-1}"
  export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/1000}"

  WAYDROID="${waydroid}/bin/waydroid"
  SLEEP="${pkgs.coreutils}/bin/sleep"

  # 1. Contenedor: si el servicio no está activo, arrancarlo.
  if ! systemctl is-active --quiet waydroid-container; then
    systemctl start waydroid-container
    for _ in $(seq 1 30); do
      systemctl is-active --quiet waydroid-container && break
      "$SLEEP" 0.5
    done
  fi

  # 2. Si la sesión ya dice estar RUNNING, intentar lanzar directamente.
  if "$WAYDROID" status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    if "$WAYDROID" app launch "$PKG" >/dev/null 2>&1; then
      exit 0
    fi
    # Si falló, la sesión estaba zombi o desconectada de Wayland; limpiarla.
    "$WAYDROID" session stop >/dev/null 2>&1 || true
    "$SLEEP" 1
  fi

  # 3. Levantar sesión limpia desacoplada.
  setsid nohup "$WAYDROID" session start >/dev/null 2>&1 < /dev/null &

  # 4. Esperar a que la sesión esté RUNNING y reintentar lanzar la app
  # hasta que ActivityManager esté listo (Android tarda unos segundos en bootear).
  for _ in $(seq 1 30); do
    if "$WAYDROID" status 2>/dev/null | grep -q "Session:.*RUNNING"; then
      if "$WAYDROID" app launch "$PKG" >/dev/null 2>&1; then
        exit 0
      fi
    fi
    "$SLEEP" 1
  done

  # 5. Último intento si aún no salió.
  exec "$WAYDROID" app launch "$PKG"
''
