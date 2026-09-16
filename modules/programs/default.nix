# Módulo "programs": shells y programas de usuario.
# Un "mod" que compone sub-programas.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./fish
    ./ghostty
    ./waybar
    ./swaync
    ./equibop
    ./nautilus
    ./yazi
    ./gtk
    ./obs-studio
    ./obs-pwvideo
    ./hyprlock
    ./waydroid
    ./virtualbox
    ./gentle-ai
    ./steam
    ./steamidra
    ./veadotube-mini
  ];
}
