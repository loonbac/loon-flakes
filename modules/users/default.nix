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
  };
}
