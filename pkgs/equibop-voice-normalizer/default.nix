{ pkgs }:

pkgs.runCommand "equibop-voice-normalizer" { } ''
  mkdir -p "$out/share/equibop-voice-normalizer"
  cp ${./main.js} "$out/share/equibop-voice-normalizer/main.js"
  cp ${./preload.js} "$out/share/equibop-voice-normalizer/preload.js"
  { echo '(() => {'; cat ${./audio.js} ${./renderer.js}; echo '})();'; } > "$out/share/equibop-voice-normalizer/renderer.js"
''
