# Módulo "system/brightness": abstracción unificada para el control de brillo
# de pantalla entre panel interno (sysfs/brightnessctl) y monitor externo (DDC/CI).
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.brightness;

  internalBrightness = pkgs.callPackage ../../pkgs/screen-brightness { };

  ddcBrightness = pkgs.callPackage ../../pkgs/ddc-brightness {
    monitorModel = "GM3CC236";
  };

  # Wrapper para que el comando unificado `screen-brightness` invoque a
  # `ddc-brightness` en hosts con backend DDC/CI.
  screenBrightnessDdcWrapper = pkgs.writeShellScriptBin "screen-brightness" ''
    exec ${ddcBrightness}/bin/ddc-brightness "$@"
  '';
in
{
  options.hardware.brightness = {
    backend = lib.mkOption {
      type = lib.types.enum [ "internal" "ddc" ];
      default = "internal";
      description = "Backend de control de brillo: panel interno (sysfs/brightnessctl) o monitor externo (DDC/CI).";
    };

    command = lib.mkOption {
      type = lib.types.str;
      default = "screen-brightness";
      description = "Nombre del comando unificado para control de brillo.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.backend == "internal") {
      environment.systemPackages = [
        internalBrightness
      ];
    })
    (lib.mkIf (cfg.backend == "ddc") {
      environment.systemPackages = [
        ddcBrightness
        screenBrightnessDdcWrapper
      ];
    })
  ];
}
