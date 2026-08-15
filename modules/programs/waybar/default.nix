# Módulo "programs/waybar": barra de estado Waybar con config gestionada por NixOS.
#
# Configura el tema V2.8 adaptado a Niri y sincronizado con la paleta
# completa de colores extraída dinámicamente del wallpaper por `accent-wallpaper`.
{ config, lib, pkgs, ... }:

let
  restartWaybar = pkgs.writeShellScriptBin "omarchy-restart-waybar" ''
    pkill -x waybar || true
    sleep 0.2
    setsid ${pkgs.waybar}/bin/waybar >/dev/null 2>&1 &
  '';
in
{
  environment.systemPackages = with pkgs; [
    waybar
    restartWaybar
  ];

  # Config gestionada por NixOS: waybar la lee desde el home (symlinks).
  environment.etc."waybar/config.jsonc".source = ./config.jsonc;
  environment.etc."waybar/style.css".source = ./style.css;

  # Fuerza que la config del home sean symlinks a la gestionada.
  # El dir se crea explícitamente con dueño correcto.
  systemd.tmpfiles.rules = [
    "d /home/loonbac/.config/waybar 0755 loonbac users -"
    "L+ /home/loonbac/.config/waybar/config.jsonc - - - - /etc/waybar/config.jsonc"
    "L+ /home/loonbac/.config/waybar/style.css - - - - /etc/waybar/style.css"
    # Paleta dinámica del wallpaper: la escribe accent-wallpaper (archivo
    # real del usuario, NO symlink). Estos defaults (f = crea si no existe)
    # evitan que el @import de style.css falle en el primer boot.
    "f /home/loonbac/.config/waybar/colors.css 0644 loonbac users - @define-color background #11181A;\n@define-color background_alt #1B2629;\n@define-color surface #1B2629;\n@define-color foreground #F0EDE1;\n@define-color accent #AB9A5E;\n@define-color on_accent #000000;\n@define-color highlight #7679C6;\n@define-color muted #8C8877;\n@define-color warning #E6A545;\n@define-color critical #E6506B;\n@define-color transparent transparent;\n"
    "f /home/loonbac/.config/waybar/accent.css 0644 loonbac users - @define-color accent #AB9A5E;\n@define-color on_accent #000000;\n"
  ];
}
