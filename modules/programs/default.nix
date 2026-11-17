# Módulo "programs": shells y programas de usuario.
# Un "mod" que compone sub-programas.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./fish
    ./ghostty
    ./rust
    ./waybar
    ./swaync
    ./equibop
    ./omafiles
    ./yazi
    ./wine
    ./gtk
    ./obs-studio
    ./obs-pwvideo
    ./hyprlock
    ./virtualbox
    ./gentle-ai
    ./pi-ssh-clipboard
    ./steam
    ./steamidra
    ./veadotube-mini
    ./pear-desktop
  ];
}
