# Módulo "wayland/niri": compositor Wayland niri (scrollable-tiling).
# Cada compositor/servicio en su propia carpeta, como un crate.
#
# La configuración (config.kdl) se gestiona desde NixOS:
#   - Se instala en /etc/niri/config.kdl (fuente de verdad, versionada).
#   - Un tmpfiles rule crea ~/.config/niri/config.kdl como symlink a
#     /etc/niri/config.kdl (niri da prioridad al home, por eso el symlink).
# Edita el archivo config.kdl de este repo y corre `rebuild`.
{ config, lib, pkgs, ... }:

{
  programs.niri = {
    enable = true;
  };

  # Config gestionada por NixOS: niri la lee como fallback desde /etc/niri.
  environment.etc."niri/config.kdl".source = ./config.kdl;

  # Fuerza que la config del home sea un symlink a la gestionada,
  # reemplazando el default que niri genera en el primer arranque.
  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    "L+ /home/loonbac/.config/niri/config.kdl - - - - /etc/niri/config.kdl"
    # Fondo animado (mpvpaper): el video vive en ~/Videos/Wallpapers.
    "d /home/loonbac/Videos 0755 loonbac users -"
    "d /home/loonbac/Videos/Wallpapers 0755 loonbac users -"
  ];
}
