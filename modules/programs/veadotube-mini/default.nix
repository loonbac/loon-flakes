{ config, lib, pkgs, ... }:

let
  cfg = config.programs.veadotube-mini;
in
{
  options.programs.veadotube-mini = {
    enable = lib.mkEnableOption "Veadotube Mini";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.veadotube-mini or (pkgs.callPackage ../../../pkgs/veadotube-mini { });
      defaultText = lib.literalExpression "pkgs.veadotube-mini";
      description = "Veadotube Mini package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isx86_64;
        message = "programs.veadotube-mini only supports x86_64-linux.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
  };
}
