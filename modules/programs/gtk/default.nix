# Módulo "programs/gtk": tema de iconos y colores custom para apps GTK.
#
# - Instala Papirus (tema de iconos completo: iconos por tipo de archivo —
#   PDF, imágenes, código, carpetas — en vez del fallback genérico de hicolor).
# - Papirus-Dark para el modo oscuro.
# - gtk.css gestionado por NixOS: se instala en /etc/gtk-4.0/gtk.css y
#   ~/.config/gtk-4.0/gtk.css es symlink (tmpfiles). accent-wallpaper
#   sobreescribe el archivo con el color de acento del wallpaper.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    papirus-icon-theme
  ];

  # Tema de iconos global (org.gnome.desktop.interface) — se aplica a
  # Nautilus y demás apps GTK.
  programs.dconf.profiles."user".databases = [
    {
      settings = {
        "org/gnome/desktop/interface" = {
          icon-theme = "Papirus-Dark";
        };
      };
    }
  ];

  # gtk.css base: el archivo del usuario lo gestiona accent-wallpaper (que
  # lo sobreescribe con el acento del wallpaper). Este `f` crea el default
  # solo si no existe (no pisa lo que accent-wallpaper escriba).
  environment.etc."gtk-4.0/gtk.css".source = ./gtk.css;

  systemd.tmpfiles.rules = [
    # El dir y el archivo deben ser del usuario (accent-wallpaper los escribe).
    "d /home/saito/.config/gtk-4.0 0755 saito users -"
    "f /home/saito/.config/gtk-4.0/gtk.css 0644 saito users -"
    # GTK3 (blueman): el único archivo que GTK3 lee es el del home, no
    # /etc/gtk-3.0/gtk.css (verificado: XDG_CONFIG_DIRS solo trae /etc/xdg).
    # Sin este `f`, accent-wallpaper igual lo crea, pero un home nuevo tendría
    # el path ausente hasta el primer cambio de wallpaper.
    "d /home/saito/.config/gtk-3.0 0755 saito users -"
    "f /home/saito/.config/gtk-3.0/gtk.css 0644 saito users -"
  ];
}
