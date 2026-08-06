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
}
