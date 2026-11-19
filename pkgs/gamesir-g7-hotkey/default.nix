{ pkgs }:

# Reemite el paddle L4 del GameSir G7 HE como F14. El nodo del mando se lee
# sin grabarlo, así que el juego sigue recibiendo el botón original.
pkgs.writeShellApplication {
  name = "gamesir-g7-hotkey";
  runtimeInputs = [
    (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.evdev ]))
  ];
  text = ''
    exec python3 ${./gamesir-g7-hotkey.py}
  '';
}
