# Aplicaciones de juegos exclusivas del PC de escritorio.
{ citron-nextendo, pkgs, ... }:

let
  # Dolphin conserva su lanzador normal, pero su audio se dirige al sink
  # exclusivo que Sunshine captura para la sesión de juego remoto.
  dolphinForStreaming = pkgs.symlinkJoin {
    name = "dolphin-emu-for-streaming";
    paths = [ pkgs.dolphin-emu ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/dolphin-emu" \
        --set PULSE_SINK dolphin_stream
    '';
    inherit (pkgs.dolphin-emu) meta;
  };
in
{
  programs.steamidra.enable = true;
  programs.citron-nextendo = {
    enable = true;
    # El Ryzen 7 5700X soporta el baseline x86-64-v3 de la build optimizada.
    package = citron-nextendo.packages.${pkgs.stdenv.hostPlatform.system}.citron-nextendo-v3;
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

  # Sober suele publicar el audio del juego a volumen completo. Dale un
  # volumen inicial perceptual del 10 % en cada stream nuevo, sin impedir que
  # el usuario lo cambie mientras juega. PipeWire representa el volumen con
  # curva cúbica, por eso 10 % equivale a 0.1³ = 0.001.
  services.pipewire.wireplumber.extraConfig."51-sober-volume" = {
    "stream.rules" = [
      {
        matches = [
          {
            "media.class" = "Stream/Output/Audio";
            "application.name" = "Sober";
          }
        ];
        actions.update-props = {
          "state.default-volume" = 0.001;
          # No restaures el volumen de la ejecución anterior: 10 % es el
          # punto de partida, no un limitador que persiga el control en vivo.
          "state.restore-props" = false;
        };
      }
    ];
  };

  environment.systemPackages = [
    dolphinForStreaming
    pkgs.heroic
  ];
}
