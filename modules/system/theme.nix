# Módulo "system/theme": lo que hace que el sistema se vea como se ve.
# Fuentes del sistema, modo oscuro global de GTK/GNOME y asociaciones MIME
# por defecto (navegador). Solo presentación; no define servicios ni el
# catálogo de paquetes de trabajo.
{ pkgs, ... }:

{
  # ---- Modo oscuro global ----
  # Las apps GTK abren en dark por defecto (Nautilus, loon-bar, etc.).
  #
  # Estos dos son el ÚNICO mando que gobierna a GTK3 y a GTK4 (verificado con
  # probe sobre theme_bg_color: Adwaita => #F6F5F4, Adwaita-dark => #353535),
  # y `color-scheme` es el que siguen Chromium/Equibop/Electron.
  #
  # Ojo: aquí NO va `gtk-application-prefer-dark-theme`. Esa clave no existe en
  # gsettings-desktop-schemas 50.1 (la sustituyó `color-scheme`), así que
  # escribirla creaba un valor fantasma que nadie leía.
  #
  # accent-wallpaper sobreescribe estos valores en el user-db según el brillo
  # del wallpaper (por defecto oscuro). Como el profile de dconf lista
  # user-db primero, lo que escriba ese script manda; esto queda como default
  # mientras no haya corrido ningún cambio de fondo.
  programs.dconf.profiles."user".databases = [
    {
      settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          gtk-theme = "Adwaita-dark";
        };
      };
    }
  ];

  # gtk-theme = "Adwaita-dark" solo funciona si el directorio del tema existe:
  # GTK3 lo busca en XDG_DATA_DIRS/themes y, si falta, cae al Adwaita claro
  # (#F6F5F4) pese a que todo el sistema pide oscuro. El shim aporta ese
  # directorio importando el CSS oscuro embebido en libgtk-3.so.
  # Sin él, blueman y el resto de apps GTK3 se ven claros (verificado 2026-11-07).
  environment.systemPackages = [ (pkgs.callPackage ../../pkgs/adwaita-dark-theme { }) ];

  # ---- Fuentes del sistema (Nerd Fonts y FontAwesome para Waybar) ----
  fonts.packages = with pkgs; [
    nerd-fonts.symbols-only
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    font-awesome
  ];

  # ---- Navegador por defecto global (Helium) ----
  # Zen Browser se retiró el 2026-11-10; Helium es el navegador del sistema
  # (mismo criterio que el de tu fork): no captura `x-scheme-handler/chrome`
  # ni los tipos propios de Firefox (`application/vnd.mozilla.xul+xml`).
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
      "text/xml" = "helium.desktop";
      "application/xml" = "helium.desktop";
      "application/xhtml+xml" = "helium.desktop";
      "image/svg+xml" = "helium.desktop";
      "image/webp" = "helium.desktop";
    };
  };
}
