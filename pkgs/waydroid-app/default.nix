# Paquete "waydroid-app": lanza una app de Android como ventana de escritorio.
#
# "Abrir TikTok Lite" debe sentirse como una app nativa: sin el launcher de
# Android, sin barra de navegación, sin reloj ni avisos de actualización.
# Waydroid tiene dos capas que pueden estar caídas (contenedor systemd y
# sesión gráfica). Este wrapper las levanta bajo demanda y deja la app en
# multi-ventana (una ventana Wayland por app).
#
#   waydroid-app com.zhiliaoapp.musically.go   # TikTok Lite
#
# Requisitos:
#   - El usuario puede controlar waydroid-container sin sudo vía polkit
#     (regla en modules/programs/waydroid/default.nix).
#   - El contenedor debe estar inicializado (waydroid init ya hecho).
{ pkgs, lib, waydroid ? pkgs.waydroid-nftables }:

let
  hideChrome = pkgs.writeShellScriptBin "waydroid-hide-chrome" ''
    set -eu
    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      echo "waydroid-hide-chrome necesita root" >&2
      exit 1
    fi

    ${pkgs.python3}/bin/python3 ${./patch-cfg.py}

    WAYDROID="${waydroid}/bin/waydroid"
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet waydroid-container; then
      exit 0
    fi

    # waydroid parsea flags (--user, -c); `--` + sh -c evita que se los coma.
    wdsh() { "$WAYDROID" shell -- sh -c "$1" >/dev/null 2>&1 || true; }
    # Barra de nav tipo teclas físicas: Android no dibuja la barra de 3 botones.
    wdsh 'setprop qemu.hw.mainkeys 1'
    # Sin status bar / nav bar dentro de la app.
    wdsh 'settings put global policy_control immersive.full=*'
    # Sin heads-up (el globo de "hay una actualización de Android").
    wdsh 'settings put global heads_up_notifications_enabled 0'
    # El actualizador de Lineage/Waydroid es el que emite esos avisos.
    wdsh 'pm disable-user --user 0 org.lineageos.waydroidupdater'
    wdsh 'cmd overlay enable org.lineageos.overlay.customization.navbar.nohint'
  '';

  app = pkgs.writeShellScriptBin "waydroid-app" ''
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
    SUDO="${pkgs.sudo}/bin/sudo"

    # 1. Contenedor: si el servicio no está activo, arrancarlo.
    if ! systemctl is-active --quiet waydroid-container; then
      systemctl start waydroid-container
      for _ in $(seq 1 30); do
        systemctl is-active --quiet waydroid-container && break
        "$SLEEP" 0.5
      done
    fi

    # 2. Multi-ventana: cada app es una ventana de escritorio, no el
    # teléfono Android completo (reloj, barra, notificaciones del sistema).
    MW=$("$WAYDROID" prop get persist.waydroid.multi_windows 2>/dev/null || true)
    if [ "$MW" != "true" ]; then
      "$WAYDROID" prop set persist.waydroid.multi_windows true >/dev/null 2>&1 || true
      if "$WAYDROID" status 2>/dev/null | grep -q "Session:.*RUNNING"; then
        "$WAYDROID" session stop >/dev/null 2>&1 || true
        "$SLEEP" 1
      fi
    fi

    # 3. Si la sesión ya dice estar RUNNING, intentar lanzar directamente.
    if "$WAYDROID" status 2>/dev/null | grep -q "Session:.*RUNNING"; then
      "$SUDO" ${hideChrome}/bin/waydroid-hide-chrome >/dev/null 2>&1 || true
      if "$WAYDROID" app launch "$PKG" >/dev/null 2>&1; then
        exit 0
      fi
      # Si falló, la sesión estaba zombi o desconectada de Wayland; limpiarla.
      "$WAYDROID" session stop >/dev/null 2>&1 || true
      "$SLEEP" 1
    fi

    # 4. Levantar sesión limpia desacoplada (sin show-full-ui).
    setsid nohup "$WAYDROID" session start >/dev/null 2>&1 < /dev/null &

    # 5. Esperar a que la sesión esté RUNNING y reintentar lanzar la app
    # hasta que Android esté listo y el proceso de la app esté activo.
    for _ in $(seq 1 30); do
      if "$WAYDROID" status 2>/dev/null | grep -q "Session:.*RUNNING"; then
        "$SUDO" ${hideChrome}/bin/waydroid-hide-chrome >/dev/null 2>&1 || true
        "$WAYDROID" app launch "$PKG" >/dev/null 2>&1 || true
        if ${pkgs.procps}/bin/pgrep -f "$PKG" >/dev/null 2>&1; then
          exit 0
        fi
      fi
      "$SLEEP" 1
    done

    # 6. Último intento si aún no salió.
    exec "$WAYDROID" app launch "$PKG"
  '';
in
pkgs.symlinkJoin {
  name = "waydroid-app";
  paths = [ app hideChrome ];
  passthru = { inherit hideChrome; };
  meta = {
    description = "Lanza apps de Waydroid como ventanas de escritorio";
    license = lib.licenses.mit;
  };
}
