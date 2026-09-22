# Módulo "programs/pear-desktop": Pear Desktop con sumidero virtual PipeWire opcional.
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.pear-desktop;

  # Fuerza únicamente a Pear a usar el sumidero virtual. El .desktop incluido
  # conserva el mismo Exec, por lo que también funciona desde el lanzador.
  pearDesktopForTwitch = pkgs.symlinkJoin {
    name = "pear-desktop-for-twitch";
    paths = [ pkgs.pear-desktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/pear-desktop" \
        --set PULSE_SINK pear_twitch
    '';
    inherit (pkgs.pear-desktop) meta;
  };
in
{
  options.programs.pear-desktop = {
    twitchSink = lib.mkEnableOption "sumidero virtual `pear_twitch` para que OBS capture el audio de Pear; solo tiene sentido en la máquina de streaming (sin loopback, el audio no se escucha por los altavoces)";
  };

  config = {
    # OBS puede capturar `pear_twitch.monitor` como dispositivo de entrada. No
    # existe loopback al dispositivo físico: el monitoreo queda a cargo de OBS.
    services.pipewire.extraConfig.pipewire-pulse."40-pear-twitch" = lib.mkIf cfg.twitchSink {
      "pulse.cmd" = [
        {
          cmd = "load-module";
          args = "module-null-sink sink_name=pear_twitch sink_properties=device.description=Pear-Twitch rate=48000 channels=2";
          flags = [ ];
        }
      ];
    };

    # La laptop recibe Pear estándar porque no transmite y el audio debe salir
    # por la salida física del sistema; la máquina de streaming usa el wrapper.
    environment.systemPackages = [
      (if cfg.twitchSink then pearDesktopForTwitch else pkgs.pear-desktop)
    ];
  };
}
