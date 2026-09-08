# NVMe ext4 exclusivo de nixos-pc para proyectos y datos de trabajo.
# Se identifica por UUID para no depender del nombre /dev/nvme0n1.
{ pkgs, ... }:

{
  fileSystems."/home/loonbac/Proyectos" = {
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
    requires = [ "home-loonbac-Proyectos.mount" ];
    after = [ "home-loonbac-Proyectos.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/chown loonbac:users /home/loonbac/Proyectos
      ${pkgs.coreutils}/bin/chmod 0755 /home/loonbac/Proyectos
    '';
  };
}
