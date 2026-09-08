# Aplicaciones de juegos exclusivas del PC de escritorio.
{ pkgs, ... }:

{
  programs.steamidra.enable = true;

  loon.programs.steam = {
    enable = true;
    spaceThemeFix.enable = true;
  };

  # Sober es distribuido oficialmente mediante Flathub. Este módulo se
  # importa solo en nixos-pc, por lo que ni Flatpak ni Roblox llegan a la laptop.
  services.flatpak = {
    enable = true;
    packages = [ "org.vinegarhq.Sober" ];
  };

  environment.systemPackages = [
    pkgs.heroic
  ];
}
