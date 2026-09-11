# Módulo "programs/equibop": cliente Discord Equibop con fix de WebRTC.
#
# Con Tailscale (o cualquier VPN) activo, WebRTC se confunde y se bindea a la
# interfaz de la VPN, quedando el voice chat colgado en "DTLS Connecting".
# El fix (el mismo de Vesktop PR #1283): forzar la política de IP de WebRTC a
# "default_public_and_private_interfaces" para que use las interfaces públicas
# y privadas pero NO la de la VPN (comentario del propio código de Vesktop:
# "Switching to 'default_public_and_private_interfaces' may fix calls stuck
# at 'DTLS Connecting' when using VPNs, Tailscale, etc.").
#
# OJO: el valor "disable_non_proxied_udp" NO sirve — desactiva todo el UDP
# directo y deja el media en "RTC Connecting" sin poder conectar.
# OJO: una bandera de Chromium (--webrtc-ip-handling-policy=...) NO sirve aquí
# porque Equibop no la lee. El fix real es llamar a la API de Electron
# webContents.setWebRTCIPHandlingPolicy(...) desde el proceso main, igual que
# hace Vesktop. Por eso parcheamos el app.asar: se extrae, se inyecta el hook
# en dist/js/main.js y se reempaqueta.
{ config, lib, pkgs, ... }:

let
  obs-overlay = pkgs.callPackage ../../../pkgs/equibop-obs-overlay { };
  voice-normalizer = pkgs.callPackage ../../../pkgs/equibop-voice-normalizer { };
  equibop-fixed = pkgs.equibop.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.asar ];

    postFixup =
      (old.postFixup or "")
      + ''
        # Parchear el app.asar: inyectar el hook que fija la política WebRTC
        # en cada webContents creado (mismo fix que Vesktop PR #1283).
        asar extract "$out/opt/Equibop/resources/app.asar" "$TMPDIR/equibop-asar"
        cat >> "$TMPDIR/equibop-asar/dist/js/main.js" <<'PATCH'
        // Da a Equibop una identidad de audio propia en Linux. Chromium ejecuta
        // AudioService fuera del proceso por defecto y termina publicando todos
        // los clientes Electron como "Chromium". Al mantenerlo dentro del
        // proceso, Electron puede propagar el nombre real a Pulse/PipeWire.
        (() => {
          if (process.platform !== "linux") return;
          const { app } = require("electron");
          try { app.setDesktopName("equibop.desktop"); } catch (_) {}

          const disabled = new Set(
            app.commandLine.getSwitchValue("disable-features").split(",").filter(Boolean)
          );
          disabled.add("AudioServiceOutOfProcess");
          app.commandLine.removeSwitch("disable-features");
          app.commandLine.appendSwitch("disable-features", [...disabled].join(","));
        })();
        PATCH
        cat >> "$TMPDIR/equibop-asar/dist/js/main.js" <<'PATCH'
        require("electron").app.on("web-contents-created", (_e, c) => {
          try { c.setWebRTCIPHandlingPolicy("default_public_and_private_interfaces"); } catch (_) {}
        });
        PATCH
        cat ${../../../pkgs/equibop-obs-overlay/main.js} >> "$TMPDIR/equibop-asar/dist/js/main.js"
        cat ${../../../pkgs/equibop-obs-overlay/preload.js} >> "$TMPDIR/equibop-asar/dist/js/preload.js"
        install -Dm0644 ${../../../pkgs/equibop-obs-overlay/renderer.js} "$TMPDIR/equibop-asar/dist/js/obs-overlay-renderer.js"
        cat ${../../../pkgs/equibop-voice-normalizer/main.js} >> "$TMPDIR/equibop-asar/dist/js/main.js"
        cat ${../../../pkgs/equibop-voice-normalizer/preload.js} >> "$TMPDIR/equibop-asar/dist/js/preload.js"
        install -Dm0644 ${../../../pkgs/equibop-voice-normalizer/renderer.js} "$TMPDIR/equibop-asar/dist/js/voice-normalizer-renderer.js"

        asar pack "$TMPDIR/equibop-asar" "$out/opt/Equibop/resources/app.asar"

        # libvesktop se carga dinámicamente desde app.asar. Electron no ve
        # sus dependencias Nix por defecto, así que el tray nativo falla y
        # Waybar recibe el menú vacío de Electron. El wrapper garantiza que
        # dlopen encuentre tanto libstdc++ como GLib al arrancar Equibop.
        wrapProgram "$out/bin/equibop" \
          --set PULSE_PROP 'application.name=Equibop application.process.binary=equibop application.icon_name=equibop media.role=phone' \
          --prefix LD_LIBRARY_PATH : '${lib.makeLibraryPath [ pkgs.stdenv.cc.cc pkgs.glib ]}'

      '';
  });
in
{
  environment.systemPackages = [ equibop-fixed obs-overlay voice-normalizer ];
  # Expone el renderer bajo una ruta estable. El proceso de Equibop vigila
  # este enlace y recarga el lector cuando un nixos-rebuild instala una
  # versión nueva, sin tener que reiniciar el cliente.
  environment.pathsToLink = [
    "/share/equibop-obs-overlay"
    "/share/equibop-voice-normalizer"
  ];

  # El servidor sólo escucha 127.0.0.1:5123. Equibop deja el estado saneado
  # bajo XDG_RUNTIME_DIR y OBS carga el HTML desde localhost; nada se envía a
  # Discord, Reactive ni a un servicio externo.
  systemd.user.services.equibop-obs-overlay = {
    description = "Overlay local de voz de Equibop para OBS";
    wantedBy = [ "loon-niri-session.target" ];
    after = [ "niri.service" ];
    partOf = [ "loon-niri-session.target" ];
    serviceConfig = {
      ExecStart = "${obs-overlay}/bin/equibop-obs-overlay";
      Restart = "on-failure";
      RestartSec = "1s";
      Environment = [
        "HOME=/home/loonbac"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      ];
    };
  };

  # Autostart gestionado por NixOS (mismo patrón que ghostty/niri):
  # se instala en /etc/equibop/ y un tmpfiles rule crea el symlink en el home.
  environment.etc."equibop/autostart.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Equibop
    Comment=Equibop autostart script
    Exec=equibop
    StartupNotify=false
    Terminal=false
    Icon=equibop
  '';

  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    "d /home/loonbac/.config/autostart 0755 loonbac users -"
    "L+ /home/loonbac/.config/autostart/equibop.desktop - - - - /etc/equibop/autostart.desktop"
  ];
}
