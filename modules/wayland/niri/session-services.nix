# Procesos persistentes de la sesión Niri.
#
# No se lanzan desde `spawn-at-startup`: systemd los supervisa, evita
# duplicados, los reinicia tras un fallo y los detiene junto con la sesión.
{ lib, pkgs, ... }:

let
  loonLaunch = pkgs.callPackage ../../../pkgs/loon-launch { };
  accentWallpaper = pkgs.callPackage ../../../pkgs/accent-wallpaper { };
  mpvpaperWallpaper = pkgs.callPackage ../../../pkgs/mpvpaper-wallpaper {
    accent-wallpaper = accentWallpaper;
  };
  wallpaperVisibility = pkgs.callPackage ../../../pkgs/niri-wallpaper-visibility {
    inherit mpvpaperWallpaper;
  };
  sessionUnit = {
    wantedBy = [ "loon-niri-session.target" ];
    after = [ "niri.service" ];
    partOf = [ "loon-niri-session.target" ];
  };
  resilientService = {
    Restart = "on-failure";
    RestartSec = "1s";
    Environment = [
      "HOME=/home/loonbac"
      # Las unidades NixOS reciben por defecto un PATH mínimo. Los módulos de
      # Waybar y los Exec de los .desktop necesitan los wrappers y paquetes
      # del sistema completo, igual que los procesos lanzados por Niri.
      "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
    ];
  };
in
{
  systemd.user.targets.loon-niri-session = {
    description = "Servicios persistentes del escritorio Niri de Loon";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "niri.service" ];
    partOf = [ "graphical-session.target" ];
  };

  systemd.user.services.waybar = sessionUnit // {
    description = "Barra custom de la sesión Niri";
    serviceConfig = resilientService // {
      ExecStart = "${pkgs.waybar}/bin/waybar --config /etc/waybar/config.jsonc --style /etc/waybar/style.css";
      ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR2 $MAINPID";
    };
  };

  systemd.user.services.swaync = sessionUnit // {
    description = "Centro de notificaciones de la sesión Niri";
    serviceConfig = resilientService // {
      Type = "dbus";
      BusName = "org.freedesktop.Notifications";
      ExecStart = "${pkgs.swaynotificationcenter}/bin/swaync -c /etc/swaync/config.json -s /etc/swaync/style.css";
      ExecReload = "${pkgs.swaynotificationcenter}/bin/swaync-client --reload-config ; ${pkgs.swaynotificationcenter}/bin/swaync-client --reload-css";
    };
  };

  # programs.hyprlock ya declara esta unidad y su ExecStart; aquí cambiamos
  # únicamente su pertenencia al target. El symlink de configuración se crea
  # declarativamente antes de que pueda comenzar la sesión.
  systemd.user.services.hypridle = sessionUnit // {
    wantedBy = lib.mkForce [ "loon-niri-session.target" ];
    description = "Bloqueo por inactividad de la sesión Niri";
    serviceConfig = resilientService;
  };

  systemd.user.services.loon-launch = sessionUnit // {
    description = "Launcher persistente de la sesión Niri";
    serviceConfig = resilientService // {
      ExecStart = "${loonLaunch}/bin/loon-launch";
    };
  };

  systemd.user.services.niri-wallpaper-visibility = sessionUnit // {
    description = "Pausa el wallpaper animado detrás de ventanas opacas";
    serviceConfig = resilientService // {
      ExecStart = "${wallpaperVisibility}/bin/niri-wallpaper-visibility";
      ExecStopPost = "${mpvpaperWallpaper}/bin/mpvpaper-wallpaper resume opaque-window";
      Restart = "always";
    };
  };

  systemd.user.services.udiskie = sessionUnit // {
    description = "Automontaje de medios extraíbles de la sesión Niri";
    serviceConfig = resilientService // {
      ExecStart = "${pkgs.udiskie}/bin/udiskie --automount --notify";
    };
  };

  systemd.user.services.wl-clip-persist = sessionUnit // {
    description = "Persistencia del portapapeles Wayland";
    serviceConfig = resilientService // {
      ExecStart = "${pkgs.wl-clip-persist}/bin/wl-clip-persist --clipboard both";
    };
  };

  systemd.user.services.cliphist-text = sessionUnit // {
    description = "Historial de texto del portapapeles Wayland";
    serviceConfig = resilientService // {
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";
    };
  };

  systemd.user.services.cliphist-image = sessionUnit // {
    description = "Historial de imágenes del portapapeles Wayland";
    serviceConfig = resilientService // {
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store";
    };
  };
}
