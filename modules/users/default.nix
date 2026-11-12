# Módulo "users": definición de usuarios del sistema.
# Quién puede usar qué.
{ config, lib, pkgs, ... }:

let
  inherit (config.loon) username home fullName;
in
{
  users.users.${username} = {
    isNormalUser = true;
    description = fullName;
    # Grupos: networkmanager (GUI de red), wheel (sudo), storage (montaje sin sudo).
    extraGroups = [ "networkmanager" "wheel" "storage" ];
    # Paquetes instalados SOLO para este usuario (home-manager se integra aquí).
    packages = with pkgs; [ ];
    # Shell por defecto: fish.
    shell = pkgs.fish;
  };

  # npm global: instala en ~/.npm-global (el prefix del store de Nix es
  # inmutable y no se puede escribir). El PATH se gestiona en system/fish para
  # que los wrappers declarativos de NixOS tengan prioridad.
  systemd.tmpfiles.rules = [
    # Esqueleto mínimo de un home nuevo. Los módulos de aplicaciones declaran
    # sus subdirectorios concretos; estas bases evitan padres creados como root.
    "d ${home}/.config 0755 ${username} users -"
    "d ${home}/.local 0755 ${username} users -"
    "d ${home}/.local/share 0755 ${username} users -"
    "d ${home}/Pictures 0755 ${username} users -"
    "d ${home}/Pictures/Wallpaper 0755 ${username} users -"
    "d ${home}/Videos 0755 ${username} users -"
    "d ${home}/Videos/Wallpapers 0755 ${username} users -"
    "d ${home}/.npm-global 0755 ${username} users -"
    "d ${home}/.npm-global/lib 0755 ${username} users -"
    "d ${home}/.npm-global/bin 0755 ${username} users -"
  ];

  environment.sessionVariables = {
    # Tema de cursor por defecto del sistema (Win11OSX, Xcursor nativo).
    XCURSOR_THEME = "Win11OSX";
    XCURSOR_SIZE = "32";
    # Para apps GTK/Qt/Electron que leen su propio cursor.
    GTK_CURSOR_THEME = "Win11OSX";
    GTK_CURSOR_SIZE = "32";
    # Modo oscuro para apps Electron/Chromium (Equibop, VS Code) que leen
    # GTK_THEME en vez de dconf.
    GTK_THEME = "Adwaita-dark";
  };
}
