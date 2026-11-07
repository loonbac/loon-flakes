# Módulo "extras-disk": montaje automático del disco secundario (sda1, "Extras")
# en /home/saito/Proyectos. Identificado por UUID para que no dependa del
# nombre de dispositivo (sda puede cambiar entre reinicios).
{ lib, ... }:

{
  fileSystems."/home/saito/Proyectos" = {
    device = "/dev/disk/by-uuid/a4bf173e-08f6-40c8-967c-588a5b164ee4";
    fsType = "ext4";
    options = [ "defaults" ];
  };
}
