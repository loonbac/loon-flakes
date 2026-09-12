# Aplicaciones de streaming exclusivas del PC de escritorio.
{ pkgs, ... }:

let
  twitchGladosTts = pkgs.callPackage ../../pkgs/obs-twitch-glados-tts { };
  obsAitumVertical = pkgs.callPackage ../../pkgs/obs-aitum-vertical { };
  obsAudioMonitor = pkgs.callPackage ../../pkgs/obs-audio-monitor { };
  obsNiriWindowCapture = pkgs.callPackage ../../pkgs/obs-niri-window-capture { };

  # OBS no ofrece una ruta declarativa global para scripts: los guarda dentro
  # de cada colección de escenas. Este wrapper registra el script de forma
  # idempotente antes de que OBS lea la colección y después arranca OBS normal.
  obsWithTwitchGladosTts = pkgs.symlinkJoin {
    name = "obs-studio-with-twitch-glados-tts";
    paths = [ pkgs.obs-studio ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/obs" \
        --run '${twitchGladosTts}/bin/obs-twitch-glados-autoload'
    '';
    inherit (pkgs.obs-studio) meta passthru;
  };

  # OBS comprueba NVENC mediante un proceso auxiliar que carga
  # libnvidia-encode.so.1 dinámicamente. En NixOS, la biblioteca del driver
  # activo vive bajo /run/opengl-driver y no forma parte del wrapper genérico.
  # Este paquete vacío aporta el argumento soportado por wrapOBS sin fijar una
  # versión concreta del driver NVIDIA en el store.
  obsNvidiaRuntime =
    pkgs.runCommand "obs-nvidia-runtime"
      {
        passthru.obsWrapperArguments = [
          "--prefix LD_LIBRARY_PATH : /run/opengl-driver/lib"
        ];
      }
      ''
        mkdir -p "$out"
      '';
in
{
  programs.veadotube-mini.enable = true;
  programs.obs-pwvideo.enable = true;
  programs.obs-studio.package = obsWithTwitchGladosTts;
  programs.obs-studio.plugins = [
    obsAitumVertical
    obsAudioMonitor
    obsNiriWindowCapture
    obsNvidiaRuntime
    pkgs.obs-studio-plugins.obs-pipewire-audio-capture
  ];

  # Ruta estable que OBS conserva en la colección aunque cambie la generación.
  environment.etc."obs-scripts/twitch-glados-tts.py".source =
    "${twitchGladosTts}/share/obs-scripts/twitch-glados-tts.py";
}
