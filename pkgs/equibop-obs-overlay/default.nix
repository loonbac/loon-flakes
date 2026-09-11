{ runCommand, writeShellApplication, python3 }:

let
  launcher = writeShellApplication {
    name = "equibop-obs-overlay";
    runtimeInputs = [ python3 ];
    text = ''
      exec ${python3}/bin/python3 ${./server.py} "$@"
    '';
  };
in
runCommand "equibop-obs-overlay" { } ''
  mkdir -p "$out/bin" "$out/share/equibop-obs-overlay"
  ln -s ${launcher}/bin/equibop-obs-overlay "$out/bin/equibop-obs-overlay"
  cp ${./renderer.js} "$out/share/equibop-obs-overlay/renderer.js"
''
