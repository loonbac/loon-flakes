# Módulo "system/theme": lo que hace que el sistema se vea como se ve.
# Fuentes del sistema, modo oscuro global de GTK/GNOME y navegador por defecto.
# Solo presentación; no define servicios ni el catálogo de paquetes de trabajo.
{ pkgs, ... }:

{
  # ---- Modo oscuro global ----
  # Las apps GTK abren en dark por defecto (Nautilus, etc.).
  programs.dconf.profiles."user".databases = [
    {
      settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          gtk-theme = "Adwaita-dark";
          gtk-application-prefer-dark-theme = true;
        };
      };
    }
  ];

  # ---- Fuentes del sistema (Nerd Fonts y FontAwesome para Waybar) ----
  fonts.packages = with pkgs; [
    nerd-fonts.symbols-only
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    font-awesome
  ];

  # ---- Navegador por defecto ----
  # Firefox se retiró; Helium (helium-browser) es el navegador del sistema.
  xdg.mime = {
    enable = true;
    defaultApplications = {
      "text/html" = "helium.desktop";
      "x-scheme-handler/http" = "helium.desktop";
      "x-scheme-handler/https" = "helium.desktop";
      "x-scheme-handler/about" = "helium.desktop";
      "x-scheme-handler/unknown" = "helium.desktop";
      "application/pdf" = "helium.desktop";
      "application/json" = "helium.desktop";
      "application/xml" = "helium.desktop";
      "text/xml" = "helium.desktop";
      "application/xhtml+xml" = "helium.desktop";
      "image/svg+xml" = "helium.desktop";
      "image/webp" = "helium.desktop";
    };
  };
}
