{ config, lib, pkgs, ... }:

let
  cfg = config.programs.steamidra;
in
{
  options.programs.steamidra = {
    enable = lib.mkEnableOption "SteaMidra";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { });
      defaultText = lib.literalExpression "pkgs.steamidra";
      description = ''
        The SteaMidra package to install. SteaMidra requires graphics
        acceleration and an X11 or XWayland-capable display environment;
        those prerequisites remain the responsibility of the host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          pkgs.stdenv.hostPlatform.isLinux
          && pkgs.stdenv.hostPlatform.isx86_64;
        message = "programs.steamidra is only supported on x86_64-linux.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
  };
}
