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

  # ---- Fuentes del sistema (Nerd Fonts y FontAwesome para la barra Quickshell) ----
  fonts.packages = with pkgs; [
    nerd-fonts.symbols-only
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    font-awesome
  ];

  # ---- Navegador por defecto global (Helium) ----
  xdg.mime = {
    enable = true;
    defaultApplications = {
      "text/html" = "helium.desktop";
      "x-scheme-handler/http" = "helium.desktop";
      "x-scheme-handler/https" = "helium.desktop";
      "x-scheme-handler/chrome" = "helium.desktop";
      "x-scheme-handler/about" = "helium.desktop";
      "x-scheme-handler/unknown" = "helium.desktop";
      "application/pdf" = "helium.desktop";
      "application/json" = "helium.desktop";
      "text/xml" = "helium.desktop";
      "application/xml" = "helium.desktop";
      "application/xhtml+xml" = "helium.desktop";
      "application/x-extension-htm" = "helium.desktop";
      "application/x-extension-html" = "helium.desktop";
      "application/x-extension-shtml" = "helium.desktop";
      "application/x-extension-xhtml" = "helium.desktop";
      "application/x-extension-xht" = "helium.desktop";
      "image/svg+xml" = "helium.desktop";
      "image/webp" = "helium.desktop";
      "application/vnd.mozilla.xul+xml" = "helium.desktop";
    };
  };
}
