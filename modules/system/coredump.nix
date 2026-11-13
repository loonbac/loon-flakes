# Política de coredumps de ambas máquinas.
#
# Tres problemas distintos, y el último es el que tumbó el sistema:
#
# 1. Un proceso gráfico grande con SIGSEGV bloqueaba el SSD durante minutos
#    mientras systemd-coredump copiaba decenas de GiB. Se conserva en el journal
#    el evento del fallo, pero no se procesa ni almacena su imagen de memoria.
#
# 2. `Storage = "none"` NO evita que el kernel entre en la ruta de coredump. El
#    `kernel.core_pattern` apunta a systemd-coredump por pipe, así que el kernel
#    abre el canal y espera en `vfs_coredump` a que el helper lo lea, aunque el
#    helper después decida no guardar nada. Con una avalancha de procesos que
#    abortan a la vez el socket se satura (MaxConnections=16) y el helper —que
#    corre dentro de systemd-journald— se queda esperando. El journald bloqueado
#    deja de escribir logs y el sistema parece congelado aunque tenga CPU y RAM
#    de sobra; el kernel lo delata con:
#
#      INFO: task systemd-journal blocked for more than 122 seconds.
#      Call Trace: wait_for_completion_state -> vfs_coredump
#      systemd-journald.service: State 'stop-watchdog' timed out.
#
#    La causa del incidente del 2026-11-13 en nixos-pc: 185 abortos en un
#    arranque (`mldr`, el cargador Mach-O de Darling del port de FL Studio;
#    `qemu-aarch64` de los trabajos de CTF) contra 16 conexiones del socket.
#
# 3. `RLIMIT_CORE = 0` tampoco basta, y esto se midió en esta máquina: con
#    `core_pattern` en pipe el kernel invoca al helper igual, porque el límite
#    sólo decide si se escribe el volcado, no si se abre el canal. Un servicio
#    de prueba con `ulimit -c = 0` que abortaba seguía produciendo su evento
#    `systemd-coredump[...]: Process ... terminated abnormally`.
#
# Por eso el ajuste que de verdad corta el bloqueo es `core_pipe_limit`: con 0
# el kernel NO espera a que el helper termine de leer, así que journald no
# puede quedarse atascado en `vfs_coredump` aunque el socket se sature. Se
# mantiene `RLIMIT_CORE = 0` como complemento económico (el helper no llega a
# escribir nada) y decorativo para el análisis posterior, que `Storage = "none"`
# ya descartaba.
{ ... }:

{
  systemd.coredump.settings.Coredump = {
    Storage = "none";
    ProcessSizeMax = 0;
  };

  # El ajuste que resuelve el bloqueo. En 0 el kernel no se queda esperando a
  # que userspace drene el canal del volcado, así que un journald saturado
  # devuelve el control en vez de colgarse en `vfs_coredump`.
  boot.kernel.sysctl."kernel.core_pipe_limit" = 0;

  # Complemento: los procesos que abortan no escriben volcado, así el helper
  # tiene menos trabajo. No impide la invocación (ver el comentario de arriba),
  # pero reduce el coste de cada avalancha.
  systemd.settings.Manager.DefaultLimitCORE = 0;

  security.pam.loginLimits = [
    {
      domain = "*";
      type = "-";
      item = "core";
      value = "0";
    }
  ];
}
