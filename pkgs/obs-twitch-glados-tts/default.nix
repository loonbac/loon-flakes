{
  lib,
  stdenvNoCC,
  fetchurl,
  sherpa-onnx,
  python3,
  jq,
  coreutils,
  gnugrep,
  gnused,
  bash,
  makeWrapper,
}:

let
  model = stdenvNoCC.mkDerivation {
    pname = "vits-piper-es-ES-glados-medium-fp32";
    version = "2025-12-05";

    src = fetchurl {
      url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-glados-medium.tar.bz2";
      hash = "sha256-39E7OZSk7Yc56uqjSoEb/B3Bxx6cj5XYkNx3OVJx9nE=";
    };

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R . "$out/"
      runHook postInstall
    '';
  };

  script = stdenvNoCC.mkDerivation {
    pname = "obs-twitch-glados-tts-script";
    version = "1.0.0";

    src = ./twitch-glados-tts.py;
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/obs-scripts"
      substitute "$src" "$out/share/obs-scripts/twitch-glados-tts.py" \
        --replace-fail '@ttsBinary@' '${lib.getExe' sherpa-onnx "sherpa-onnx-offline-tts"}' \
        --replace-fail '@ttsModel@' '${model}/es_ES-glados-medium.onnx' \
        --replace-fail '@ttsTokens@' '${model}/tokens.txt' \
        --replace-fail '@ttsDataDir@' '${model}/espeak-ng-data'
      runHook postInstall
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "obs-twitch-glados-tts";
  version = "1.0.0";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/obs-scripts"
    ln -s '${script}/share/obs-scripts/twitch-glados-tts.py' \
      "$out/share/obs-scripts/twitch-glados-tts.py"

    makeWrapper '${lib.getExe bash}' "$out/bin/obs-twitch-glados-autoload" \
      --add-flags '${./install-autoload.sh}' \
      --set OBS_TWITCH_TTS_PYTHON_PATH '${python3}/lib' \
      --prefix PATH : '${lib.makeBinPath [ jq coreutils gnugrep gnused ]}'

    runHook postInstall
  '';

  passthru = {
    inherit model script;
  };

  meta = {
    description = "Native OBS script for local Twitch GLaDOS TTS";
    platforms = lib.platforms.linux;
  };
}
