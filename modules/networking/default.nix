# Módulo "networking": todo lo relacionado con red.
# La capa de conexión con el mundo.
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
  # 5173 = dev server de Vite del frontend tele-owo; 8080 = API axum (Rust).
  networking.firewall.allowedTCPPorts = [ 5173 8080 ];
}
