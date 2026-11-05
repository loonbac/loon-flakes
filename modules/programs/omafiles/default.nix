# Módulo "programs/omafiles": explorador de archivos GUI por defecto.
#
# Sustituye a Nautilus como manejador de `inode/directory`. omafiles es nativo
# de Wayland (GPUI) y lee los tokens de tema de Omarchy; en NixOS ese
# directorio no existe, así que arranca con su `fallback-theme.toml` neutro y
# lo avisa por stderr. Ver AGENTS.md.
#
# Nautilus se retiró de este módulo cuando omafiles pasó a ser el explorador
# por defecto, pero `file-roller` se conserva: aporta la integración gráfica
# de archivos comprimidos y no depende de Nautilus. `gvfs` llega por
# modules/services/udisks2 y `programs.dconf` por modules/system, así que
# ninguno de los dos se declara aquí.
{ pkgs, ... }:

{
  environment.systemPackages = [
    (pkgs.callPackage ../../../pkgs/omafiles { })
    pkgs.file-roller
    pkgs.p7zip
  ];

  # Asociación MIME por defecto. Sin esto el sistema sigue abriendo
  # `inode/directory` con Nautilus (o con nada, tras retirarlo). El nombre del
  # .desktop tiene que ser el app_id (`dev.omarchy.omafiles`) o Wayland no
  # asocia la ventana con la entrada.
  xdg.mime.defaultApplications = {
    "inode/directory" = "dev.omarchy.omafiles.desktop";
  };
}
