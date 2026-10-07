# Módulo "system/theme": lo que hace que el sistema se vea como se ve.
# Fuentes del sistema, modo oscuro global de GTK/GNOME y asociaciones MIME
# por defecto (navegador). Solo presentación; no define servicios ni el
# catálogo de paquetes de trabajo.
{ pkgs, ... }:

{
  # ---- Modo oscuro global ----
  # Las apps GTK abren en dark por defecto (Nautilus, loon-bar, etc.).
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

  # ---- Navegador por defecto global (Zen Browser) ----
  xdg.mime = {
    enable = true;
    defaultApplications = {
      "text/html" = "zen.desktop";
      "x-scheme-handler/http" = "zen.desktop";
      "x-scheme-handler/https" = "zen.desktop";
      "x-scheme-handler/chrome" = "zen.desktop";
      "x-scheme-handler/about" = "zen.desktop";
      "x-scheme-handler/unknown" = "zen.desktop";
      "application/pdf" = "zen.desktop";
      "application/json" = "zen.desktop";
      "text/xml" = "zen.desktop";
      "application/xml" = "zen.desktop";
      "application/xhtml+xml" = "zen.desktop";
      "application/x-extension-htm" = "zen.desktop";
      "application/x-extension-html" = "zen.desktop";
      "application/x-extension-shtml" = "zen.desktop";
      "application/x-extension-xhtml" = "zen.desktop";
      "application/x-extension-xht" = "zen.desktop";
      "image/svg+xml" = "zen.desktop";
      "image/webp" = "zen.desktop";
      "application/vnd.mozilla.xul+xml" = "zen.desktop";
    };
  };
}
