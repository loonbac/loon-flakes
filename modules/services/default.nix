# Módulo "services": agregador de servicios del sistema.
# Un "mod" que compone sub-servicios.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./openssh
    ./tailscale
    ./nixos-updates
    ./udisks2
  ];
}
