# Módulo "programs/ghostty": terminal ghostty con config gestionada por NixOS.
#
# La config (config) se instala en /etc/ghostty/config (fuente de verdad,
# versionada) y un tmpfiles rule crea ~/.config/ghostty/config como symlink.
# Ghostty da prioridad a ~/.config/ghostty/config, por eso el symlink.
# Edita el archivo config de este repo y corre `rebuild`.
{ config, lib, pkgs, ... }:

{
  # Config y shaders gestionados por NixOS: ghostty los lee desde el home (symlinks).
  environment.etc."ghostty/config".source = ./config;
  environment.etc."ghostty/shaders/smooth_cursor.glsl".source = ./shaders/smooth_cursor.glsl;

  # Fuerza que la config y los shaders del home sean symlinks a los gestionados.
  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    "L+ /home/loonbac/.config/ghostty/config - - - - /etc/ghostty/config"
    "d /home/loonbac/.config/ghostty/shaders 0755 loonbac users -"
    "L+ /home/loonbac/.config/ghostty/shaders/smooth_cursor.glsl - - - - /etc/ghostty/shaders/smooth_cursor.glsl"
  ];
}
