{ config, lib, pkgs, ... }:

let
  cfg = config.programs.obs-pwvideo;
in
{
  options.programs.obs-pwvideo = {
    enable = lib.mkEnableOption "the OBS PipeWire Video Source plugin";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.obs-pwvideo or (pkgs.callPackage ../../../pkgs/obs-pwvideo { });
      defaultText = lib.literalExpression "pkgs.obs-pwvideo";
      description = "OBS PipeWire Video Source plugin package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux;
        message = "programs.obs-pwvideo is only supported on Linux.";
      }
    ];

    programs.obs-studio = {
      enable = true;
      plugins = [ cfg.package ];
    };
  };
}
