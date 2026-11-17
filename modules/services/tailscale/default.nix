# Servicio Tailscale: red privada mesh entre dispositivos (VPN WireGuard).
# Tras el rebuild: `sudo tailscale up` para autenticar y unir la máquina a la tailnet.
#
# El bypass por túnel SSH (`services.ts-bypass`) se retiró el 2026-11-13: su
# único consumidor era `hosts/loon-laptop`, que ya no existe, y con él cayeron
# `pkgs/ts-bypass`, la unidad `ts-bypass-tunnel`, el `knownHosts` de su VPS y
# los tres helpers de estado del `let` anterior. Tailscale queda tal cual:
# solo se activa el servicio.
{ ... }:

{
  services.tailscale.enable = true;
}
