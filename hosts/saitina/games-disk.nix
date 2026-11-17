# Discos NTFS secundarios compartidos con Windows: HELL, DATA y NAH. Se
# montan en ~/Games/<etiqueta> (no en /run/media, que solo existe mientras
# udisks la monta bajo demanda): así la ruta es estable entre arranques y la
# usan los programas con rutas fijas — TwintailLauncher usa ~/Games/HELL como
# biblioteca de juegos y Steam guarda una biblioteca por disco.
#
# uid/gid explícitos: montado por fstab en boot no pasa por udisks, que es
# quien inyecta uid=$UID,gid=$GID; sin ellos los archivos saldrían root.
# `force` es obligatorio: Windows deja los volúmenes "dirty" al apagar con
# Inicio Rápido y ntfs3 se niega a montarlos sin esa opción (mismo motivo
# que /etc/udisks2/mount_options.conf en default.nix). `nofail`: sin el
# disco el arranque no se detiene.
{ ... }:

let
  # Opciones comunes de los tres discos (mismo conjunto que ya usaba HELL).
  ntfsOptions = [
    "uid=1000"
    "gid=100"
    "force"
    "iocharset=utf8"
    "nofail"
  ];
in
{
  fileSystems."/home/saito/Games/HELL" = {
    device = "/dev/disk/by-uuid/5A744E6E744E4D47";
    fsType = "ntfs3";
    options = ntfsOptions;
  };

  fileSystems."/home/saito/Games/DATA" = {
    device = "/dev/disk/by-uuid/5C20444720442A7A";
    fsType = "ntfs3";
    options = ntfsOptions;
  };

  fileSystems."/home/saito/Games/NAH" = {
    device = "/dev/disk/by-uuid/0282C2DC82C2D2F9";
    fsType = "ntfs3";
    options = ntfsOptions;
  };

  # El punto de montaje lo crea root al arrancar; tmpfiles le da propiedad
  # y modo al usuario para que exista también con el disco desconectado.
  systemd.tmpfiles.rules = [
    "d /home/saito/Games 0755 saito users -"
    "d /home/saito/Games/HELL 0755 saito users -"
    "d /home/saito/Games/DATA 0755 saito users -"
    "d /home/saito/Games/NAH 0755 saito users -"
  ];
}
