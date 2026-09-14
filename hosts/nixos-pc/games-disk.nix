# Almacenamiento ext4 exclusivo de nixos-pc. Se identifica por UUID para no
# depender del nombre que el kernel asigne a cada disco en un arranque.
{ ... }:

{
  fileSystems."/home/loonbac/Juegos" = {
    device = "/dev/disk/by-uuid/dd98ba9a-bcf5-4062-828c-099b51b4d7a4";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };

  fileSystems."/home/loonbac/Datos" = {
    device = "/dev/disk/by-uuid/96417a54-5f22-4aad-a6f3-8125a6f7a7d4";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };

  # Los directorios raíz de ext4 nacen propiedad de root; tmpfiles ajusta la
  # propiedad después de montar para que el usuario pueda escribir en ellos.
  systemd.tmpfiles.rules = [
    "d /home/loonbac/Juegos 0755 loonbac users -"
    "d /home/loonbac/Datos 0755 loonbac users -"
  ];
}
