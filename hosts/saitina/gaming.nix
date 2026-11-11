# Capacidad de juegos de saitina: Steam (Millennium + Accela, vía el módulo
# compartido loon.programs.steam) y TwintailLauncher (paquete propio del repo).
{ pkgs, ... }:

{
  loon.programs.steam.enable = true;

  environment.systemPackages = [
    (pkgs.callPackage ../../pkgs/twintaillauncher { })
  ];
}
