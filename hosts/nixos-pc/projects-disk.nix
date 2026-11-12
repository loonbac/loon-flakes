# NVMe ext4 exclusivo de nixos-pc para proyectos y datos de trabajo.
# Se identifica por UUID para no depender del nombre /dev/nvme0n1.
{ config, pkgs, ... }:

{
  fileSystems."${config.loon.home}/Proyectos" = {
    device = "/dev/disk/by-uuid/98648f36-b315-406b-b84d-65c1865544af";
    fsType = "ext4";
    options = [
      "defaults"
      "nofail"
    ];
  };

  # La raíz de un ext4 nuevo pertenece a root. Esta unidad se ordena después
  # del montaje para que los permisos se apliquen al filesystem, también en el
  # primer switch donde la unidad .mount aún no existía al correr tmpfiles.
  systemd.services.projects-disk-permissions = {
    description = "Permisos del NVMe de proyectos";
    wantedBy = [ "multi-user.target" ];
    requires = [ "home-${config.loon.username}-Proyectos.mount" ];
    after = [ "home-${config.loon.username}-Proyectos.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/chown ${config.loon.username}:users ${config.loon.home}/Proyectos
      ${pkgs.coreutils}/bin/chmod 0755 ${config.loon.home}/Proyectos
    '';
  };
}
