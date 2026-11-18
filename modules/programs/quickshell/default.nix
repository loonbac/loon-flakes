# Módulo "programs/quickshell": barra de estado Wayland gestionada por NixOS.
#
# La configuración QML vive en `loonbar/` y se publica como /etc/quickshell/loonbar.
# El servicio de usuario la arranca con `qs -p` (modo ruta): así el id del shell
# no depende del nombre de un symlink en el home.
{ config, lib, pkgs, ... }:

let
  paletteDefaults = "@define-color background #11181A; @define-color background_alt #1B2629; @define-color surface #1B2629; @define-color foreground #F0EDE1; @define-color accent #AB9A5E; @define-color on_accent #000000; @define-color highlight #7679C6; @define-color muted #8C8877; @define-color warning #E6A545; @define-color critical #E6506B; @define-color transparent transparent;";
  accentDefaults = "@define-color accent #AB9A5E; @define-color on_accent #000000;";
in
{
  options.loon.quickshell.screen = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Nombre de la salida Wayland donde se muestra la barra; null la muestra en todas.";
  };

  config = {
    environment.systemPackages = with pkgs; [
      quickshell
    ];

    environment.etc."quickshell/loonbar".source = ./loonbar;

    systemd.tmpfiles.rules = [
      "d ${config.loon.home}/.config/loon-shell 0755 ${config.loon.username} users -"
      # accent-wallpaper escribe estos archivos reales; las reglas f solo los
      # siembran cuando todavía no existen, igual que hacía la configuración anterior.
      "f ${config.loon.home}/.config/loon-shell/colors.css 0644 ${config.loon.username} users - ${paletteDefaults}"
      "f ${config.loon.home}/.config/loon-shell/accent.css 0644 ${config.loon.username} users - ${accentDefaults}"
    ];
  };
}
