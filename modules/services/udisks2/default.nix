# Módulo "services/udisks2": daemon de gestión y montaje de almacenamiento (USB, discos).
# Permite que GVFS (Nautilus) y udiskie detecten, monten automáticamente y expulsen dispositivos.
{ config, lib, pkgs, ... }:

{
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  # Reglas de Polkit para permitir a los usuarios del grupo wheel montar y desmontar
  # discos internos (SATA, NVMe) y externos sin error de "Not authorized".
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
           action.id == "org.freedesktop.udisks2.filesystem-mount" ||
           action.id == "org.freedesktop.udisks2.filesystem-mount-other-seat" ||
           action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
           action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
           action.id == "org.freedesktop.udisks2.encrypted-unlock-system" ||
           action.id == "org.freedesktop.udisks2.encrypted-unlock-other-seat" ||
           action.id == "org.freedesktop.udisks2.power-off-drive-system" ||
           action.id == "org.freedesktop.udisks2.power-off-drive-other-seat") &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';

  environment.systemPackages = with pkgs; [
    udiskie
    exfatprogs
    ntfs3g
  ];
}
