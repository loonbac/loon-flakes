# Disco de juegos NTFS "HELL" (sdc1, 953.9G) — partición Windows compartida.
# Se monta en ~/Games/HELL (no en /run/media, que solo existe mientras
# udisks la monta bajo demanda): así la ruta es estable entre arranques y
# la usa TwintailLauncher como biblioteca de juegos.
#
# uid/gid explícitos: montado por fstab en boot no pasa por udisks, que es
# quien inyecta uid=$UID,gid=$GID; sin ellos los archivos saldrían root.
# `force` es obligatorio: Windows deja los volúmenes "dirty" al apagar con
# Inicio Rápido y ntfs3 se niega a montarlos sin esa opción (mismo motivo
# que /etc/udisks2/mount_options.conf en default.nix). `nofail`: sin el
# disco el arranque no se detiene.
{ ... }:

{
  fileSystems."/home/saito/Games/HELL" = {
    device = "/dev/disk/by-uuid/5A744E6E744E4D47";
    fsType = "ntfs3";
    options = [
      "uid=1000"
      "gid=100"
      "force"
      "iocharset=utf8"
      "nofail"
    ];
  };

  # El punto de montaje lo crea root al arrancar; tmpfiles le da propiedad
  # y modo al usuario para que exista también con el disco desconectado.
  systemd.tmpfiles.rules = [
    "d /home/saito/Games 0755 saito users -"
    "d /home/saito/Games/HELL 0755 saito users -"
  ];
}
