# Paquete "adwaita-dark-theme": shim que hace que `Adwaita-dark` exista como
# tema real para GTK3.
#
# Sin esto, `gtk-theme = "Adwaita-dark"` (tanto en dconf como en el env
# GTK_THEME) NO resuelve: GTK3 busca el directorio `share/themes/Adwaita-dark`
# y, al no encontrarlo, cae al tema por defecto que es CLARO (#F6F5F4). Por eso
# blueman y el resto de apps GTK3 se ven claros aunque todo el sistema diga
# oscuro. Verificado el 2026-11-07 con probes sobre theme_bg_color: con el
# shim da #353535 (oscuro) y sin él da #F6F5F4 (claro).
#
# La variante oscura de Adwaita no vive en un directorio: va embebida en
# libgtk-3.so como recurso. Este paquete solo aporta el directorio con un
# gtk.css que importa ese recurso, igual que hace el propio gtk-dark.css de
# Adwaita. No es un pin: importa un recurso del GTK en ejecución, así que
# sigue la versión de gtk3 del sistema.
{ lib, runCommand }:

runCommand "adwaita-dark-theme"
  {
    meta = {
      description = "Directorio de tema Adwaita-dark que importa el CSS oscuro embebido de GTK3";
      license = lib.licenses.gpl2Plus;
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir -p $out/share/themes/Adwaita-dark/gtk-3.0
    cat > $out/share/themes/Adwaita-dark/gtk-3.0/gtk.css <<'EOF'
    @import url("resource:///org/gtk/libgtk/theme/Adwaita/gtk-contained-dark.css");
    EOF

    # GTK3 recorre los directorios de temas buscando index.theme; sin él el
    # directorio se ignora.
    cat > $out/share/themes/Adwaita-dark/index.theme <<'EOF'
    [Desktop Entry]
    Type=X-GNOME-Metatheme
    Name=Adwaita-dark
    Comment=Variante oscura de Adwaita resuelta desde el recurso embebido de GTK3
    EOF
  ''
