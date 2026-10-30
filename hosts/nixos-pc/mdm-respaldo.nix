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
{ config, pkgs, ... }:

{
  systemd.services.mdm-respaldo = {
    description = "Respaldo diario del gestor MDM: base y materiales (issue #338)";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    # systemd builds a minimal PATH for system services (coreutils, findutils,
    # gnugrep, gnused, systemd). Missing from it are the three things the script
    # cannot run without: bash, because it starts with #!/usr/bin/env bash and
    # env resolves it through PATH (unit fails with 127 otherwise); docker, to
    # reach the containers; and gzip, which validates the materials archive on
    # the host rather than inside the container.
    path = [
      pkgs.bash
      config.virtualisation.docker.package
      pkgs.gzip
    ];
    serviceConfig = {
      Type = "oneshot";
      Environment = [ "MDM_RESPALDOS_DEST=/var/backups/mdm" ];
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
    path = [
      pkgs.bash
      config.virtualisation.docker.package
      pkgs.gzip
    ];
    serviceConfig = {
      Type = "oneshot";
      Environment = [ "MDM_RESPALDOS_DEST=/var/backups/mdm" ];
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
