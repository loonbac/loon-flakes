# SpaceTheme Fix instalado declarativamente para Millennium.
{ config, lib, pkgs, space-theme-fix, ... }:

let
  cfg = config.loon.programs.steam.spaceThemeFix;
  theme = pkgs.stdenvNoCC.mkDerivation {
    pname = "millennium-space-theme-fix";
    version = "unstable";
    src = space-theme-fix;

    nativeBuildInputs = [ pkgs.unzip ];
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      unzip "$src/SpaceTheme-Fix.zip" -d "$out"
      runHook postInstall
    '';
  };
in
{
  options.loon.programs.steam.spaceThemeFix.enable = lib.mkEnableOption
    "el tema SpaceTheme Fix para Millennium";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.loon.programs.steam.enable;
        message = "SpaceTheme Fix requiere loon.programs.steam.enable = true;";
      }
    ];

    # La carpeta se llama `Steam` porque ese es el identificador interno que
    # declara skin.json y que Millennium guarda en activeTheme.
    systemd.tmpfiles.rules = [
      "d /home/saito/.local/share/Steam 0755 saito users -"
      "d /home/saito/.local/share/Steam/millennium 0755 saito users -"
      "d /home/saito/.local/share/Steam/millennium/themes 0755 saito users -"
      "L+ /home/saito/.local/share/Steam/millennium/themes/Steam - - - - ${theme}"
    ];
  };
}
