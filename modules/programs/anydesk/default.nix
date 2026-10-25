# Módulo "programs/anydesk": escritorio remoto AnyDesk, con la app para el
# usuario y su servicio de sistema para conexiones entrantes (acceso no
# atendido, incluida la pantalla de login).
#
# nixpkgs no trae módulo NixOS para AnyDesk: el paquete deja la unidad
# `anydesk.service` en `$out/lib/systemd/system`. `systemd.packages` la importa
# tal cual (ExecStart ya apunta al binario del store) y `wantedBy` la habilita,
# sin reescribirla ni duplicar su configuración. El paquete viene de nixpkgs sin
# versión fijada: se actualiza con `rebuild update`.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.anydesk ];

  # Servicio en segundo plano (`anydesk --service`, User=root, LimitNOFILE alto):
  # sin él AnyDesk solo funciona mientras su GUI está abierta en una sesión y no
  # admite conexiones entrantes.
  systemd.packages = [ pkgs.anydesk ];
  systemd.services.anydesk.wantedBy = [ "multi-user.target" ];

  # La unidad arranca el binario del store directamente (sin el wrapper del
  # paquete), así que hereda el PATH mínimo de systemd: `ip`, `lsblk` y
  # `domainname` no resuelven y AnyDesk registra errores al inventariar el
  # equipo. El PATH completo del sistema los cubre sin tocar la unidad.
  systemd.services.anydesk.path = [ "/run/current-system/sw" ];
}
