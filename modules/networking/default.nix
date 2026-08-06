# Módulo "networking": todo lo relacionado con red.
# En loon-librust esto sería `core/api/mod.rs`: la capa de conexión con el mundo.
{ config, lib, pkgs, ... }:

{
  # Gestor de red (WiFi, ethernet, VPNs por GUI).
  networking.networkmanager.enable = true;

  # ---- Firewall ----
  # Por defecto NixOS activa el firewall. Para abrir puertos:
  #   networking.firewall.allowedTCPPorts = [ 80 443 ];
  #   networking.firewall.allowedUDPPorts = [ 53 ];
  # Para desactivarlo del todo (NO recomendado):
  #   networking.firewall.enable = false;
}
