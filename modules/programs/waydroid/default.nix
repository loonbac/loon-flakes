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

{
  virtualisation.waydroid.enable = true;
  virtualisation.waydroid.package = pkgs.waydroid-nftables;

  # Acceso al contenedor sin sudo: el cliente waydroid habla por D-Bus con el
  # servicio waydroid-container y los nodos /dev/binder* (controlados por
  # udev). El grupo "waydroid" se usa para los permisos de los dispositivos.
  users.groups.waydroid = { };

  users.users.loonbac.extraGroups = [ "waydroid" ];

  environment.systemPackages = [ pkgs.waydroid ];
}
