# Streaming de la pantalla actual de nixos-pc para clientes Moonlight.
{ config, pkgs, ... }:

let
  dolphinIsRunning = pkgs.writeShellScript "dolphin-is-running" ''
    ${pkgs.procps}/bin/ps -eo stat=,comm= | ${pkgs.gawk}/bin/awk '
      $1 !~ /^Z/ && $2 ~ /dolphin-emu/ { found = 1 }
      END { exit(found ? 0 : 1) }
    '
  '';

  # Mantiene viva la aplicación de Sunshine únicamente mientras Dolphin siga
  # abierto. No inicia ni termina el emulador.
  dolphinSessionMonitor = pkgs.writeShellScript "sunshine-dolphin-session" ''
    while ${dolphinIsRunning}; do
      ${pkgs.coreutils}/bin/sleep 1
    done
  '';

  # Sunshine 2026.516 cambia temporalmente el sink predeterminado cuando el
  # cliente no solicita audio local, incluso si audio_sink está configurado.
  # Conserva la última salida real elegida y revierte únicamente los sinks
  # internos sink-sunshine-* que Sunshine intenta establecer como default.
  sunshineAudioDefaultGuard = pkgs.writeShellScript "sunshine-audio-default-guard" ''
    pactl=${pkgs.pulseaudio}/bin/pactl
    preferred_sink=alsa_output.usb-MAONO_AU-AM200_MAONO_AU-AM200_20180508-00.analog-stereo

    restore_default() {
      current_sink="$($pactl get-default-sink 2>/dev/null || true)"
      case "$current_sink" in
        sink-sunshine-*)
          $pactl set-default-sink "$preferred_sink" || true
          ;;
        ?*)
          preferred_sink="$current_sink"
          ;;
      esac
    }

    while true; do
      restore_default
      while IFS= read -r _event; do
        # Consultar pactl crea y elimina un cliente PulseAudio. Si se reacciona
        # a esos eventos, cada consulta dispara otra consulta y el guard entra
        # en un bucle que consume CPU. El sink predeterminado forma parte del
        # estado del servidor, así que sólo ese tipo de cambio es relevante.
        case "$_event" in
          *" on server #"*) restore_default ;;
        esac
      done < <(LC_ALL=C $pactl subscribe 2>/dev/null)
      ${pkgs.coreutils}/bin/sleep 1
    done
  '';

  # El escritorio usa otra instancia: los permisos de entrada de Sunshine
  # son globales por instancia, no por aplicación o cliente emparejado.
  desktopStateDir = "/home/loonbac/.config/sunshine-desktop";
  desktopApps = pkgs.writeText "sunshine-desktop-apps.json" (builtins.toJSON {
    env = { };
    apps = [ { name = "Escritorio"; image = "desktop.png"; } ];
  });
  desktopConfig = pkgs.writeText "sunshine-desktop.conf" ''
    sunshine_name=nixos-pc-escritorio
    address_family=ipv4
    bind_address=100.73.247.39
    port=48189
    origin_web_ui_allowed=wan
    csrf_allowed_origins=https://100.73.247.39:48190
    capture=kms
    output_name=1
    encoder=vulkan
    keyboard=enabled
    mouse=enabled
    controller=disabled
    native_pen_touch=disabled
    system_tray=disabled
    file_apps=${desktopApps}
    credentials_file=${desktopStateDir}/sunshine_state.json
    file_state=${desktopStateDir}/sunshine_state.json
    pkey=${desktopStateDir}/credentials/cakey.pem
    cert=${desktopStateDir}/credentials/cacert.pem
    log_path=${desktopStateDir}/sunshine.log
  '';
in
{
  # Sink exclusivo para Dolphin. module-remap-sink reproduce en el sumidero
  # físico predeterminado sin mezclar el resto del audio de la sesión.
  services.pipewire.extraConfig.pipewire-pulse."45-dolphin-stream" = {
    "pulse.cmd" = [
      {
        cmd = "load-module";
        args = "module-remap-sink sink_name=dolphin_stream sink_properties=device.description=Dolphin-Stream remix=no";
        flags = [ ];
      }
    ];
  };

  services.sunshine = {
    enable = true;
    autoStart = true;
    openFirewall = true;

    # Niri requiere captura DRM/KMS; esta capacidad permite acceder al monitor
    # sin ejecutar todo Sunshine como root.
    capSysAdmin = true;
    settings = {
      sunshine_name = "nixos-pc";
      address_family = "both";
      csrf_allowed_origins = "https://192.168.0.10:47990";
      capture = "kms";
      # Sunshine 2026.516 interpreta incorrectamente el nombre estable DP-2
      # con KMS; su listado de arranque asigna el monitor principal al ID 1.
      output_name = "1";
      # En este paquete de NixOS CUDA/NVENC no resuelve libcuda.so, mientras
      # que el backend Vulkan sí codifica H.264/HEVC en la RTX 3060.
      encoder = "vulkan";
      # Captura solo el audio enviado por el wrapper de Dolphin.
      audio_sink = "dolphin_stream";
      # El invitado puede enviar únicamente el mando. Mouse, teclado y entrada
      # táctil quedan rechazados por Sunshine en el host.
      controller = "enabled";
      # Expón un mando estándar de Xbox One, compatible con Dolphin y sin
      # requerir el acceso privilegiado de los perfiles virtuales DualSense.
      gamepad = "xone";
      keyboard = "disabled";
      mouse = "disabled";
      native_pen_touch = "disabled";
    };

    # Esta entrada no lanza Dolphin: transmite el monitor que ya está activo.
    # El emulador se inicia manualmente antes de que el invitado abra el stream.
    applications.apps = [
      {
        name = "Dolphin";
        image = "desktop.png";
        cmd = "${dolphinSessionMonitor}";
        # No lanza el emulador: si Dolphin no está abierto, rechaza el stream
        # para evitar mostrar accidentalmente el resto del escritorio.
        "prep-cmd" = [
          {
            "do" = "${dolphinIsRunning}";
            "undo" = "";
          }
        ];
      }
    ];
  };

  # El servicio de usuario se instala globalmente; esta condición evita que el
  # greeter u otra cuenta intente ocupar los mismos puertos.
  systemd.user.services.sunshine.unitConfig.ConditionUser = "loonbac";

  # Solo la tailnet puede alcanzar esta segunda instancia. Tiene claves y
  # emparejamientos independientes de la instancia compartida con el amigo.
  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [ 48184 48189 48190 48210 ];
    allowedUDPPorts = [ 48198 48199 48200 48202 48210 ];
  };

  systemd.user.services.sunshine-desktop = {
    description = "Sunshine privado para el escritorio por Tailscale";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig = {
      ConditionUser = "loonbac";
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0700 ${desktopStateDir} ${desktopStateDir}/credentials";
      ExecStart = "${config.security.wrapperDir}/sunshine ${desktopConfig}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.user.services.sunshine-audio-default-guard = {
    description = "Preserva la salida de audio local durante streams de Sunshine";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "pipewire-pulse.service" ];
    serviceConfig = {
      ExecStart = "${sunshineAudioDefaultGuard}";
      Restart = "always";
      RestartSec = "1s";
    };
  };

  users.users.loonbac.extraGroups = [ "input" ];
}
