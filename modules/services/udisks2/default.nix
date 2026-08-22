# Módulo "services/udisks2": daemon de gestión y montaje de almacenamiento (USB, discos).
# Permite que GVFS (Nautilus) y udiskie detecten, monten automáticamente y expulsen dispositivos.
{ config, lib, pkgs, ... }:

{
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  environment.systemPackages = with pkgs; [
    udiskie
    exfatprogs
    ntfs3g
  ];
}
