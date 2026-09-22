# Módulo "programs/cisco-packet-tracer": simulador de redes Cisco Packet Tracer.
#
# No se instala por defecto para evitar bloquear máquinas nuevas que no posean
# el instalador propietario en su store local.
# Para instalarlo en un host, establecer `programs.cisco-packet-tracer.enable = true;`
# en el `default.nix` del host correspondiente (requiere aportar manualmente el
# .deb propietario con su hash fijado: CiscoPacketTracer900...deb mediante
# `nix store add --mode flat --hash-algo sha256 --name ... /ruta/al/.deb`).
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.cisco-packet-tracer;
in
{
  options.programs.cisco-packet-tracer = {
    enable = lib.mkEnableOption "Cisco Packet Tracer (instalador propietario aportado manualmente)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.callPackage ../../../pkgs/cisco-packet-tracer { })
    ];
  };
}
