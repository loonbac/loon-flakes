# Módulo "services/nixos-updates": servicio y timer en segundo plano para
# consultar periódicamente si existen nuevas versiones de paquetes/flake.
{ config, lib, pkgs, ... }:

let
  nixosUpdatesPkg = pkgs.callPackage ../../../pkgs/nixos-updates { };
in
{
  systemd.user.services.nixos-updates-check = {
    description = "Verificación en segundo plano de actualizaciones de NixOS";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${nixosUpdatesPkg}/bin/nixos-updates check";
      Nice = 19;
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
      CPUWeight = 10;
      IOWeight = 10;
      MemoryHigh = "2G";
      MemoryMax = "4G";
      MemorySwapMax = "2G";
      TimeoutStartSec = "20m";
    };
  };

  systemd.user.timers.nixos-updates-check = {
    description = "Timer periódico para verificar actualizaciones de NixOS";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      OnUnitActiveSec = "1h";
      Persistent = true;
      AccuracySec = "1m";
      RandomizedDelaySec = "5m";
    };
  };
}
