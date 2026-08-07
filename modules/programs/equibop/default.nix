# Módulo "programs/equibop": cliente Discord Equibop con fix de WebRTC.
#
# Con Tailscale (o cualquier VPN) activo, WebRTC se confunde y se bindea a la
# interfaz de la VPN, quedando el voice chat colgado en "DTLS Connecting".
# El fix (el mismo de Vesktop/Legcord): forzar la política de IP de WebRTC a
# "disable_non_proxied_udp" para que solo use la interfaz de la ruta por
# defecto (WiFi) y no la de la VPN.
#
# Se envuelve el binario con makeWrapper para agregar la bandera en CUALQUIER
# forma de lanzamiento (menú, launcher, terminal, autostart).
{ config, lib, pkgs, ... }:

let
  equibop-fixed = pkgs.symlinkJoin {
    name = "equibop-webrtc-fix";
    paths = [ pkgs.equibop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm -f $out/bin/equibop
      makeWrapper ${pkgs.equibop}/bin/equibop $out/bin/equibop \
        --add-flags "--webrtc-ip-handling-policy=disable_non_proxied_udp"
    '';
  };
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
