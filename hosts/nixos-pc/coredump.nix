# Evita que un proceso gráfico grande con SIGSEGV bloquee el SSD durante
# minutos mientras systemd-coredump copia decenas de GiB. Se conserva en el
# journal el evento del fallo, pero no se procesa ni almacena su imagen de
# memoria. Esta política es exclusiva del PC donde ocurrió el incidente.
{ ... }:

{
  systemd.coredump.settings.Coredump = {
    Storage = "none";
    ProcessSizeMax = 0;
  };
}
