# Módulo "programs/hyprlock": bloqueador de pantalla con blur y daemon de inactividad (hypridle).
#
# - hyprlock: bloqueador moderno Wayland (ext-session-lock-v1) con blur por shaders GPU.
# - hypridle: daemon de inactividad (ext-idle-notify-v1) que gestiona los tiempos de bloqueo y DPMS.
# - Las configuraciones se instalan en /etc/hypr y se enlazan mediante tmpfiles a ~/.config/hypr/*.
{ config, lib, pkgs, ... }:

{
  # Habilita el módulo de hyprlock en NixOS (configura el servicio PAM necesario para la autenticación)
  programs.hyprlock.enable = true;

  # Instala el daemon de inactividad hypridle
  environment.systemPackages = with pkgs; [
    hypridle
  ];

  # Configuración versionada gestionada por NixOS
  environment.etc."hypr/hyprlock.conf".source = ./hyprlock.conf;
  environment.etc."hypr/hypridle.conf".source = ./hypridle.conf;

  # Enlaces simbólicos en el home del usuario
  systemd.tmpfiles.rules = [
    "d /home/loonbac/.config/hypr 0755 loonbac users -"
    "L+ /home/loonbac/.config/hypr/hyprlock.conf - - - - /etc/hypr/hyprlock.conf"
    "L+ /home/loonbac/.config/hypr/hypridle.conf - - - - /etc/hypr/hypridle.conf"
  ];
}
