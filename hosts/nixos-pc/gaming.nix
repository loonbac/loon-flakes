# Aplicaciones de juegos exclusivas del PC de escritorio.
{ pkgs, ... }:

{
  programs.steamidra.enable = true;
  programs.citron-nextendo = {
    enable = true;
    # El Ryzen 7 5700X soporta el baseline x86-64-v3 de la build optimizada.
    # Pin temporal: los AppImage 2061df046 crashean al iniciar juegos. Este
    # artefacto se construye remotamente desde el último commit conocido bueno.
    package = pkgs.callPackage ../../pkgs/citron-nextendo {
      x86_64Variant = "v3";
      metadataFile = ../../pkgs/citron-nextendo/sources-known-good-c7e70d046.json;
    };
  };

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

    overrides."org.vinegarhq.Sober".Context = {
      # Discord Rich Presence: permite a Sober conectarse tanto al socket de
      # Discord Flatpak como al de clientes nativos (Discord/Equibop). Solo se
      # exponen estos dos endpoints del runtime del usuario.
      filesystems = [
        "xdg-run/app/com.discordapp.Discord:create"
        "xdg-run/discord-ipc-0"
      ];

      # Impide que Sober vea /dev/input (gamepads/controladores). El teclado y
      # el mouse siguen llegando normalmente a través del socket de Wayland.
      devices = [ "!input" ];
    };

    # PokeMMO necesita poder seleccionar ROMs y otros archivos guardados en
    # cualquier carpeta del usuario.
    overrides."com.pokemmo.PokeMMO".Context.filesystems = [ "home" ];
  };

  environment.systemPackages = [
    pkgs.heroic
  ];
}
