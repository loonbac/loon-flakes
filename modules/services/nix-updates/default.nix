# Módulo "services/nix-updates": servicio y timer en segundo plano para
# consultar periódicamente si existen nuevas versiones de paquetes/flake.
{ config, lib, pkgs, ... }:

let
  nixUpdatesPkg = pkgs.callPackage ../../../pkgs/nix-updates { };
in
{
  systemd.user.services.nix-updates-check = {
    description = "Verificación en segundo plano de actualizaciones de NixOS";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${nixUpdatesPkg}/bin/nix-updates check";
      Nice = 19;
    };
  };

  systemd.user.timers.nix-updates-check = {
    description = "Timer periódico para verificar actualizaciones de NixOS";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
