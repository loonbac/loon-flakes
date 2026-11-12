# Módulo "programs/swaync": daemon de notificaciones SwayNC con config gestionada por NixOS.
#
# - La config (config.json + style.css) se instala en /etc/swaync (fuente de
#   verdad, versionada) y un tmpfiles rule crea ~/.config/swaync/* como symlinks.
# - SwayNC da prioridad a ~/.config/swaync, por eso los symlinks.
# - accent.css NO es symlink: es un archivo real del usuario que
#   accent-wallpaper sobreescribe con el color del wallpaper (mismo patrón que
#   gtk.css / niri accent.kdl). El rule `f` crea el default si no existe.
# - Recarga en vivo tras un cambio de acento: `swaync-client -R`.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    swaynotificationcenter
  ];

  # Config gestionada por NixOS: swaync la lee desde el home (symlinks).
  environment.etc."swaync/config.json".source = ./config.json;
  environment.etc."swaync/style.css".source = pkgs.replaceVars ./style.css { home = config.loon.home; };

  # Ruta absoluta: systemd no expande "~" en tmpfiles.
  systemd.tmpfiles.rules = [
    "d ${config.loon.home}/.config/swaync 0755 ${config.loon.username} users -"
    "L+ ${config.loon.home}/.config/swaync/config.json - - - - /etc/swaync/config.json"
    "L+ ${config.loon.home}/.config/swaync/style.css - - - - /etc/swaync/style.css"
    # Acento dinámico: lo escribe accent-wallpaper; este default (f = crea si
    # no existe, no pisa) evita que el @import falle en el primer boot.
    "f ${config.loon.home}/.config/swaync/accent.css 0644 ${config.loon.username} users - @define-color accent #5e81ac; @define-color on_accent #ffffff;"
  ];
}
