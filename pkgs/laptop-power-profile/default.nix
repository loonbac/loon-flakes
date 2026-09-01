{ pkgs }:

pkgs.writeShellApplication {
  name = "laptop-power-profile";
  runtimeInputs = with pkgs; [ coreutils gawk gnugrep iw networkmanager ];
  text = builtins.readFile ./laptop-power-profile.sh;
}
