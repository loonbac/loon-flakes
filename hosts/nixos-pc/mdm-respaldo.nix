# Respaldos del gestor MDM (issue #338).
#
# Vive en el host y no en modules/ a propósito: los guiones, el destino
# /var/backups/mdm y el stack de contenedores que respaldan solo existen aquí.
#
# Por qué systemd del sistema y no un timer de usuario:
# - Los guiones son de root en /var/lib/mdm/bin (755). Un servicio del sistema que
#   ejecutara un guion escribible por loonbac sería una vía de escalada; con el
#   fichero en root:root el usuario puede ejecutarlo pero no reescribirlo. Los
#   enlaces de ~/.local/bin mantienen vivos los timers de usuario que ya existían.
# - /etc/systemd/system es un enlace de solo lectura al store, y cron no está
#   instalado: la única vía persistente es declararlo aquí.
#
# Los guiones NO se empaquetan en el store: se editan a mano y esa mutabilidad es
# deliberada. Nix declara quién los ejecuta y cuándo, no su contenido; una
# reinstalación limpia tiene que restaurarlos en /var/lib/mdm/bin.
#
# El destino tampoco se pasa por entorno. resolver_destino (guiones-comunes.sh) lo
# fija a /var/backups/mdm cuando corre como root y solo deja elegirlo al modo
# usuario: un proceso privilegiado que acepta su destino del entorno se envenena
# con el entorno. Declarar aquí MDM_RESPALDOS_DEST no cambiaría nada y describiría
# mal al servicio.
{ config, pkgs, ... }:

{
  systemd.services.mdm-respaldo = {
    description = "Respaldo diario del gestor MDM: base y materiales (issue #338)";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    # systemd builds a minimal PATH for system services (coreutils, findutils,
    # gnugrep, gnused, systemd) and the script needs five things that are not in
    # it. bash, because it starts with #!/usr/bin/env bash and env resolves the
    # interpreter through PATH (the unit dies with 127 before its first line);
    # docker, to reach the containers; gzip, which validates the materials
    # archive on the host rather than inside the container; tar, for the same
    # reason, since the listing that proves the archive is not empty runs here
    # and not in the container; and flock, which the verification script takes
    # before touching anything.
    #
    # Keep flock here. The verification script reads a failed flock -n as "another
    # run is in progress" and exits 0, so a missing binary turns every weekly run
    # into a silent success that verifies nothing.
    path = [
      pkgs.bash
      config.virtualisation.docker.package
      pkgs.gzip
      pkgs.gnutar
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/var/lib/mdm/bin/mdm-respaldo.sh";
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
    };
  };

  systemd.timers.mdm-respaldo = {
    description = "Timer del respaldo diario del gestor MDM";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:12:00";
      # Reparte el arranque para no chocar con otras tareas de la madrugada.
      RandomizedDelaySec = 300;
      # Si la máquina estaba apagada a las 03:12, el respaldo corre al arrancar
      # en vez de perderse.
      Persistent = true;
    };
  };

  systemd.services.mdm-verifica-respaldo = {
    description = "Verifica que el último respaldo del gestor MDM se restaura (issue #338)";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    # Same PATH as the backup unit, for the same reasons; flock is the one that
    # matters most here.
    path = [
      pkgs.bash
      config.virtualisation.docker.package
      pkgs.gzip
      pkgs.gnutar
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/var/lib/mdm/bin/mdm-verifica-respaldo.sh";
      Nice = 10;
    };
  };

  systemd.timers.mdm-verifica-respaldo = {
    description = "Timer semanal que comprueba que el respaldo del gestor MDM se restaura";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:30:00";
      RandomizedDelaySec = 600;
      Persistent = true;
    };
  };
}
