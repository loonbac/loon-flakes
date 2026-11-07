# Módulo "programs": shells y programas de usuario.
# Base de apariencia y terminal. El resto del catálogo original (gaming,
# streaming, agentes, virtualización) queda fuera hasta que se pida.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./fish
    ./ghostty
    ./rust
    ./waybar
    ./swaync
    ./gtk
    ./hyprlock
    ./equibop
  ];
}
