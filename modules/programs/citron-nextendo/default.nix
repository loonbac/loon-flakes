{ config, lib, pkgs, ... }:

let
  cfg = config.programs.citron-nextendo;
in
{
  options.programs.citron-nextendo = {
    enable = lib.mkEnableOption "Citron Nextendo";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.citron-nextendo or (pkgs.callPackage ../../../pkgs/citron-nextendo { });
      defaultText = lib.literalExpression "pkgs.citron-nextendo";
      description = "Citron Nextendo package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.elem pkgs.stdenv.hostPlatform.system [
          "x86_64-linux"
          "aarch64-linux"
        ];
        message = "programs.citron-nextendo only supports x86_64-linux and aarch64-linux.";
      }
    ];

    # El runtime AppImage monta DwarFS mediante FUSE. También instala los
    # wrappers fusermount/fusermount3 requeridos por usuarios sin privilegios.
    programs.fuse.enable = true;
    environment.systemPackages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];
  };
}
