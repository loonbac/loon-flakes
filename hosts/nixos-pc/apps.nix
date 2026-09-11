# Aplicaciones de escritorio exclusivas del PC.
{ pkgs, ... }:

let
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
  # OBS puede capturar `pear_twitch.monitor` como dispositivo de entrada. No
  # existe loopback al dispositivo físico: el monitoreo queda a cargo de OBS.
  services.pipewire.extraConfig.pipewire-pulse."40-pear-twitch" = {
    "pulse.cmd" = [
      {
        cmd = "load-module";
        args = "module-null-sink sink_name=pear_twitch sink_properties=device.description=Pear-Twitch rate=48000 channels=2";
        flags = [ ];
      }
    ];
  };

  environment.systemPackages = [
    pearDesktopForTwitch
  ];
}
