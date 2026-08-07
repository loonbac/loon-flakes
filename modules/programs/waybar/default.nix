# Módulo "programs/waybar": barra de estado Waybar con config gestionada por NixOS.
#
# La config (config.jsonc + style.css) se instala en /etc/waybar (fuente de
# verdad, versionada) y un tmpfiles rule crea ~/.config/waybar/* como symlinks.
# Waybar da prioridad a ~/.config/waybar, por eso los symlinks.
# Edita los archivos config.jsonc / style.css de este repo y corre `rebuild`.
{ config, lib, pkgs, ... }:

{
  # Config gestionada por NixOS: waybar la lee desde el home (symlinks).
  environment.etc."waybar/config.jsonc".source = ./config.jsonc;
  environment.etc."waybar/style.css".source = ./style.css;

  # Fuerza que la config del home sean symlinks a la gestionada.
  # El dir se crea explícitamente con dueño correcto: si tmpfiles-resetup
  # lo crea antes como root, luego no puede escribir los symlinks dentro.
  systemd.tmpfiles.rules = [
    "d /home/loonbac/.config/waybar 0755 loonbac users -"
    "L+ /home/loonbac/.config/waybar/config.jsonc - - - - /etc/waybar/config.jsonc"
    "L+ /home/loonbac/.config/waybar/style.css - - - - /etc/waybar/style.css"
  ];
}
