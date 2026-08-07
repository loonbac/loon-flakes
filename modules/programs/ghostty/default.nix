# Módulo "programs/ghostty": terminal ghostty con config gestionada por NixOS.
#
# La config (config) se instala en /etc/ghostty/config (fuente de verdad,
# versionada) y un tmpfiles rule crea ~/.config/ghostty/config como symlink.
# Ghostty da prioridad a ~/.config/ghostty/config, por eso el symlink.
# Edita el archivo config de este repo y corre `rebuild`.
{ config, lib, pkgs, ... }:

{
  # Config gestionada por NixOS: ghostty la lee desde el home (symlink).
  environment.etc."ghostty/config".source = ./config;

  # Fuerza que la config del home sea un symlink a la gestionada.
  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    "L+ /home/loonbac/.config/ghostty/config - - - - /etc/ghostty/config"
  ];
}
