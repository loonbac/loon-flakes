# Módulo "programs/waydroid": Android en contenedor LXC sobre el kernel nativo.
#
# No es un emulador: corre el userspace de Android (imagen AOSP) en un
# contenedor LXC sobre el mismo kernel, con renderizado GPU por hardware.
# El paquete de nixpkgs trae la imagen "vanilla" (AOSP puro, SIN Google apps)
# — la más ligera y rápida. Las apps se instalan con `waydroid app install`.
#
# El módulo de nixpkgs (virtualisation.waydroid) ya configura:
#   - lxc, el servicio waydroid-container, la config de gbinder y el firewall.
#   - Requiere binderfs y memfd en el kernel (los trae el kernel genérico).
#   - Añade "psi=1" a los kernelParams.
# Aquí añadimos el grupo "waydroid" (el módulo de nixpkgs no lo crea) para
# poder usar waydroid sin sudo, y el paquete en systemPackages.
#
# OJO: usamos waydroid-nftables (no waydroid) porque el script de red de
# waydroid usa iptables legacy (módulos ip_tables), y el kernel de nixpkgs
# no los trae (firewall por nftables). El paquete nftables-patched mueve la
# red del contenedor a nftables y arranca sin ip_tables.
{ config, lib, pkgs, ... }:

let
  # waydroid parcheado con nftables y con shebangs apuntando al shell de Nix
  waydroidPkg = pkgs.waydroid-nftables.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      if [ -f "$out/lib/waydroid/data/scripts/.waydroid-net.sh-wrapped" ]; then
        sed -i '1s|^#!/bin/sh|#!${pkgs.bash}/bin/sh|' "$out/lib/waydroid/data/scripts/.waydroid-net.sh-wrapped"
      fi
    '';
  });

  # Wrapper que levanta contenedor+sesión bajo demanda (paquete del flake).
  waydroid-app = pkgs.callPackage ../../../pkgs/waydroid-app {
    waydroid = waydroidPkg;
  };
in
{
  virtualisation.waydroid.enable = true;
  virtualisation.waydroid.package = waydroidPkg;

  # Acceso al contenedor sin sudo: el cliente waydroid habla por D-Bus con el
  # servicio waydroid-container y los nodos /dev/binder* (controlados por
  # udev). El grupo "waydroid" se usa para los permisos de los dispositivos.
  users.groups.waydroid = { };

  users.users.loonbac.extraGroups = [ "waydroid" ];

  environment.systemPackages = [ waydroidPkg waydroid-app ];

  # Arrancar el contenedor al boot: sí, pero SIN ventana. Es lo que permite
  # que "abrir TikTok" funcione de una — el contenedor está listo y solo hay
  # que levantar la sesión (rápido). Sin esto, la primera apertura tardaría
  # en bootear Android.
  systemd.services.waydroid-container.wantedBy = lib.mkForce [ "multi-user.target" ];

  # El wrapper waydroid-app necesita arrancar el contenedor sin contraseña
  # cuando está caído (systemctl start waydroid-container).
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.user == "loonbac" &&
          action.lookup("unit") == "waydroid-container.service") {
        return polkit.Result.YES;
      }
    });
  '';

  # .desktop persistente para TikTok: lanza vía waydroid-app (levanta
  # contenedor+sesión bajo demanda). El .desktop que genera Waydroid en
  # ~/.local/share/applications apunta a `waydroid app launch` directo, que
  # falla si la sesión no está corriendo.
  environment.etc."waydroid/tiktok.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=TikTok
    Comment=Android TikTok (Waydroid)
    Exec=waydroid-app com.zhiliaoapp.musically
    Icon=/home/loonbac/.local/share/waydroid/data/icons/com.zhiliaoapp.musically.png
    Categories=X-WayDroid-App;
    Terminal=false
  '';

  # Instalar el .desktop en el home del usuario (ruta absoluta: systemd no
  # expande ~ en tmpfiles).
  systemd.tmpfiles.rules = [
    "L+ /home/loonbac/.local/share/applications/tiktok.desktop - - - - /etc/waydroid/tiktok.desktop"
  ];
}
