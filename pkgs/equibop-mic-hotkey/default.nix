{ pkgs }:

pkgs.writeShellApplication {
  name = "equibop-mic-hotkey";
  runtimeInputs = [
    (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.evdev ]))
    pkgs.coreutils
    pkgs.util-linux
  ];
  text = ''
    exec python3 ${./equibop-mic-hotkey.py}
  '';
}
