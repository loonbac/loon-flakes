# Módulo "programs/waybar": barra de estado Waybar con config gestionada por NixOS.
#
# Configura el tema V2.8 adaptado a Niri y sincronizado con la paleta
# completa de colores extraída dinámicamente del wallpaper por `accent-wallpaper`.
{ config, lib, pkgs, ... }:

let
  brightnessCommand = config.hardware.brightness.command;
  isDdc = config.hardware.brightness.backend == "ddc";
  baseConfig = builtins.fromJSON (builtins.readFile ./config.jsonc);
  rightModules = baseConfig."group/right1".modules;
  hostConfig =
    (builtins.removeAttrs baseConfig
      (lib.optionals (brightnessCommand == null) [ "custom/backlight" ]))
    // {
      "group/right1" = baseConfig."group/right1" // {
        modules = if brightnessCommand != null then
          rightModules
        else
          builtins.filter (module: module != "custom/backlight") rightModules;
      };
    }
    // lib.optionalAttrs (brightnessCommand != null) {
      "custom/backlight" =
        (builtins.removeAttrs baseConfig."custom/backlight"
          (lib.optionals isDdc [ "interval" ]))
        // {
          exec = "${brightnessCommand} json";
          on-scroll-up = "${brightnessCommand} up 5";
          on-scroll-down = "${brightnessCommand} down 5";
          # Waybar vuelve a ejecutar `exec` tras cada evento por defecto. En el
          # PC el daemon ya señala cada cambio y leer el estado local es inmediato.
          "exec-on-event" = !isDdc;
        };
    };
  generatedConfig = pkgs.writeText "waybar-config.json" (builtins.toJSON hostConfig);
  restartWaybar = pkgs.writeShellScriptBin "omarchy-restart-waybar" ''
    ${pkgs.systemd}/bin/systemctl --user restart waybar.service
  '';
in
{
  environment.systemPackages = with pkgs; [
    waybar
    restartWaybar
  ];

  # Config gestionada por NixOS: waybar la lee desde el home (symlinks).
  # Cada host recibe su backend: sysfs en el Dell y DDC/CI en el PC.
  environment.etc."waybar/config.jsonc".source = generatedConfig;
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
    "f /home/loonbac/.config/waybar/colors.css 0644 loonbac users - @define-color background #11181A; @define-color background_alt #1B2629; @define-color surface #1B2629; @define-color foreground #F0EDE1; @define-color accent #AB9A5E; @define-color on_accent #000000; @define-color highlight #7679C6; @define-color muted #8C8877; @define-color warning #E6A545; @define-color critical #E6506B; @define-color transparent transparent;"
    "f /home/loonbac/.config/waybar/accent.css 0644 loonbac users - @define-color accent #AB9A5E; @define-color on_accent #000000;"
  ];
}
