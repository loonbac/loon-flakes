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
  xdg.mime = {
    enable = true;
    defaultApplications = {
      "text/html" = "firefox.desktop";
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
      "x-scheme-handler/about" = "firefox.desktop";
      "x-scheme-handler/unknown" = "firefox.desktop";
      "application/pdf" = "firefox.desktop";
      "application/json" = "firefox.desktop";
      "application/xml" = "firefox.desktop";
      "text/xml" = "firefox.desktop";
      "application/xhtml+xml" = "firefox.desktop";
      "image/svg+xml" = "firefox.desktop";
      "image/webp" = "firefox.desktop";
    };
  };
}
