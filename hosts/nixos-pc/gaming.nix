# Aplicaciones de juegos exclusivas del PC de escritorio.
{ pkgs, ... }:

{
  programs.steamidra.enable = true;

  loon.programs.steam = {
    enable = true;
    spaceThemeFix.enable = true;
  };

  # Sober y PokeMMO se instalan desde Flathub. Este módulo se importa solo en
  # nixos-pc, por lo que ni Flatpak ni estos juegos llegan a la laptop.
  services.flatpak = {
    enable = true;
    packages = [
      "org.vinegarhq.Sober"
      "com.pokemmo.PokeMMO"
    ];

    # Discord Rich Presence: permite a Sober conectarse tanto al socket de
    # Discord Flatpak como al de clientes nativos (Discord/Equibop). Solo se
    # exponen estos dos endpoints del runtime del usuario.
    overrides."org.vinegarhq.Sober".Context.filesystems = [
      "xdg-run/app/com.discordapp.Discord:create"
      "xdg-run/discord-ipc-0"
    ];

    # PokeMMO necesita poder seleccionar ROMs y otros archivos guardados en
    # cualquier carpeta del usuario.
    overrides."com.pokemmo.PokeMMO".Context.filesystems = [ "home" ];
  };

  environment.systemPackages = [
    pkgs.heroic
  ];
}
