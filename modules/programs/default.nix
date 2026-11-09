# Módulo "programs": shells y programas de usuario.
# Base de apariencia y terminal. El resto del catálogo original (gaming,
# streaming, virtualización) queda fuera hasta que se pida; el stack de
# agentes (gentle-ai/Pi/Engram) se pidió el 2026-11-08 y ya entra.
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
    ./gentle-ai
  ];
}
