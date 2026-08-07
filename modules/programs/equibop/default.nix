# Módulo "programs/equibop": cliente Discord Equibop con fix de WebRTC.
#
# Con Tailscale (o cualquier VPN) activo, WebRTC se confunde y se bindea a la
# interfaz de la VPN, quedando el voice chat colgado en "DTLS Connecting".
# El fix (el mismo de Vesktop/Legcord): forzar la política de IP de WebRTC a
# "disable_non_proxied_udp" para que WebRTC solo use la interfaz de la ruta
# por defecto (WiFi) y no la de la VPN.
#
# OJO: una bandera de Chromium (--webrtc-ip-handling-policy=...) NO sirve aquí
# porque Equibop no la lee. El fix real es llamar a la API de Electron
# webContents.setWebRTCIPHandlingPolicy("disable_non_proxied_udp") desde el
# proceso main, igual que hace Vesktop. Por eso parcheamos el app.asar:
# se extrae, se inyecta el hook en dist/js/main.js y se reempaqueta.
{ config, lib, pkgs, ... }:

let
  equibop-fixed = pkgs.equibop.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.asar ];

    postFixup =
      (old.postFixup or "")
      + ''
        # Parchear el app.asar: inyectar el hook que fija la política WebRTC
        # en cada webContents creado (mismo fix que Vesktop PR #1283).
        asar extract "$out/opt/Equibop/resources/app.asar" "$TMPDIR/equibop-asar"
        cat >> "$TMPDIR/equibop-asar/dist/js/main.js" <<'PATCH'
        require("electron").app.on("web-contents-created", (_e, c) => {
          try { c.setWebRTCIPHandlingPolicy("disable_non_proxied_udp"); } catch (_) {}
        });
        PATCH
        asar pack "$TMPDIR/equibop-asar" "$out/opt/Equibop/resources/app.asar"
      '';
  });
in
{
  environment.systemPackages = [ equibop-fixed ];

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
    "L+ /home/loonbac/.config/autostart/equibop.desktop - - - - /etc/equibop/autostart.desktop"
  ];
}
