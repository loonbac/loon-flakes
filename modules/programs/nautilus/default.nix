# Módulo "programs/nautilus": explorador de archivos GNOME (Nautilus).
#
# En NixOS 26.05 no existe la opción `programs.nautilus` (fue removida),
# así que se instala el paquete + gvfs (montajes, trash, samba) en
# systemPackages. File Roller aporta la integración gráfica de archivos
# comprimidos y p7zip el backend para abrir y extraer formatos 7-Zip.
# También se habilita `programs.dconf` para que los settings de GTK/GNOME
# funcionen en niri.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    nautilus
    gvfs
    file-roller
    p7zip
  ];

  programs.dconf.enable = true;
}
