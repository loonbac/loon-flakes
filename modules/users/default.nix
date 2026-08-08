# Módulo "users": definición de usuarios del sistema.
# Quién puede usar qué.
{ config, lib, pkgs, ... }:

{
  users.users."loonbac" = {
    isNormalUser = true;
    description = "Joshua Rosales";
    # Grupos: networkmanager (GUI de red), wheel (sudo).
    extraGroups = [ "networkmanager" "wheel" ];
    # Paquetes instalados SOLO para este usuario (home-manager se integra aquí).
    packages = with pkgs; [ ];
    # Shell por defecto: fish.
    shell = pkgs.fish;
  };

  # npm global: instala en ~/.npm-global (el prefix del store de Nix es
  # inmutable y no se puede escribir). Crea el dir y lo pone en el PATH.
  systemd.tmpfiles.rules = [
    "d /home/loonbac/.npm-global 0755 loonbac users -"
    "d /home/loonbac/.npm-global/lib 0755 loonbac users -"
    "d /home/loonbac/.npm-global/bin 0755 loonbac users -"
  ];

  environment.sessionVariables = {
    PATH = [ "$HOME/.npm-global/bin" ];
    # Tema de cursor por defecto del sistema (Win11OSX, Xcursor nativo).
    XCURSOR_THEME = "Win11OSX";
    XCURSOR_SIZE = "32";
    # Para apps GTK/Qt/Electron que leen su propio cursor.
    GTK_CURSOR_THEME = "Win11OSX";
    GTK_CURSOR_SIZE = "32";
    # Fuerza el driver VA-API de Intel (iHD) para apps que usan decodificación
    # por hardware (OBS QSV, mpv, navegadores).
    LIBVA_DRIVER_NAME = "iHD";
  };
}
