# Procesos persistentes de la sesión Niri.
#
# No se lanzan desde `spawn-at-startup`: systemd los supervisa, evita
# duplicados, los reinicia tras un fallo y los detiene junto con la sesión.
{ config, lib, pkgs, loonLaunch, ... }:

let
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
      "HOME=/home/saito"
      # Las unidades NixOS reciben por defecto un PATH mínimo. Los módulos de
      # Waybar y los Exec de los .desktop necesitan los wrappers y paquetes
      # del sistema completo, igual que los procesos lanzados por Niri.
      #
      # Los perfiles de usuario van explícitos: loon-launch ejecuta cada
      # .desktop con `systemd-run --scope sh -c`, que hereda ESTE entorno de
      # servicio, y apps como NotepadNext o Helium solo viven en
      # ~/.nix-profile/bin (no en /run/current-system/sw/bin). Sin esta línea
      # el launcher fallaba con "firefox: command not found" (2026-11-09).
      "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/home/saito/.nix-profile/bin:/etc/profiles/per-user/saito/bin:/home/saito/.local/bin"
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

  # Blueman: sin applet no hay menú de bandeja ni notificaciones de emparejado
  # (blueman-manager registra su propio agente, pero el estado y los avisos de
  # conexión los gestiona el applet). Solo donde el host habilita blueman.
  #
  # El paquete ya publica su unidad (Type=dbus, BusName=org.blueman.Applet,
  # ExecStart propio): declarar otro ExecStart la deja inválida ("more than
  # one ExecStart"). Aquí solo se la adhiere a la sesión y se le dan
  # reinicio/PATH, que es lo que aporta el patrón de este archivo.
  systemd.user.services.blueman-applet = lib.mkIf config.services.blueman.enable (sessionUnit // {
    description = "Applet de Bluetooth de la sesión Niri";
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "1s";
      Environment = resilientService.Environment;
    };
  });

  # services.blueman.enable instala su blueman.desktop en
  # /run/current-system/sw/etc/xdg/autostart/, y
  # systemd-xdg-autostart-generator lo convierte en app-blueman@autostart.
  # Con la unidad de arriba eso deja DOS applets a la vez: ambos cargan
  # plugins y ambos registran agentes, así que compiten por rfkill y por el
  # estado del adaptador (pasó el 2026-11-07: PIDs 1267 y 1284).
  #
  # Se tapa con un .desktop en /etc/xdg, que va PRIMERO en XDG_CONFIG_DIRS y
  # por eso gana al del paquete. Hidden=true es lo que la spec XDG y el
  # generador de systemd entienden por "no arranques esto" (verificado con y
  # sin la sombra: la unidad solo se genera cuando la sombra no existe).
  # Se queda la de arriba por ser la supervisada, con reinicio y atada a
  # loon-niri-session.target, que es el patrón de este archivo.
  environment.etc."xdg/autostart/blueman.desktop" = lib.mkIf config.services.blueman.enable {
    text = ''
      [Desktop Entry]
      Type=Application
      Name=Blueman
      Exec=${pkgs.blueman}/bin/blueman-applet
      Hidden=true
    '';
  };

  # Agente de autenticación Polkit de la sesión. Sin él, cualquier acción que
  # pida autorización (montar un disco con Disks, instalar un paquete desde un
  # .desktop, gestionar red) no tiene con qué responder al usuario y falla en
  # silencio.
  systemd.user.services.polkit-gnome = sessionUnit // {
    description = "Agente de autenticación Polkit para Niri";
    serviceConfig = resilientService // {
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
  };
}
