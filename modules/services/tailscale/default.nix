# Servicio Tailscale: red privada mesh entre dispositivos (VPN WireGuard).
# Tras el rebuild: `sudo tailscale up` para autenticar y unir la máquina a la tailnet.
{ config, lib, pkgs, ... }:

{
  services.tailscale = {
    enable = true;
  };
}
