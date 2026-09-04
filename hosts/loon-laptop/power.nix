# Política automática AC/batería exclusiva del Dell Inspiron 15 3520.
# Este archivo solo debe importarse desde hosts/loon-laptop/default.nix.
{ pkgs, ... }:

let
  powerProfile = pkgs.callPackage ../../pkgs/laptop-power-profile { };
  systemctl = "${pkgs.systemd}/bin/systemctl";

  triggerSessionProfile = pkgs.writeShellApplication {
    name = "loon-laptop-power-session-trigger";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd ];
    text = ''
      # La sesión niri importa NIRI_SOCKET al gestor systemd del usuario.
      # Que aún no exista sesión gráfica durante el arranque es normal y no
      # debe hacer fallar el perfil de hardware.
      if [ -S /run/user/1000/bus ]; then
        systemctl --user --machine=loonbac@.host \
          restart laptop-power-profile-session.service || true
      fi
    '';
  };
in
{
  environment.systemPackages = [
    powerProfile
    pkgs.hdparm
    pkgs.nvme-cli
    pkgs.powertop
  ];

  # Ahorro declarativo del audio inactivo. Este Dell usa snd_hda_intel;
  # un segundo es conservador y no deshabilita el audio.
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=1 power_save_controller=Y
  '';

  # El receptor conectado actualmente es KYE 0458:019d, no el Telink visto
  # por PowerTOP anteriormente. Se mantiene despierto para evitar lag o
  # desconexiones; no se habilita autosuspend USB global.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0458", ATTR{idProduct}=="019d", TEST=="power/control", ATTR{power/control}="on"
  '';

  systemd.services.laptop-power-profile = {
    description = "Perfil automático de hardware AC/batería de loon-laptop";
    wantedBy = [ "multi-user.target" ];
    after = [ "bluetooth.service" "NetworkManager.service" ];
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "laptop-power-profile";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
      ExecStart = "${powerProfile}/bin/laptop-power-profile apply";
      ExecStartPost = "${triggerSessionProfile}/bin/loon-laptop-power-session-trigger";
    };
  };

  systemd.user.services.laptop-power-profile-session = {
    description = "Perfil de refresco niri y wallpaper de loon-laptop";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session-pre.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${powerProfile}/bin/laptop-power-profile-session apply";
      Environment = "HOME=/home/loonbac";
    };
  };

  # El adaptador Dell puede emitir ráfagas online/offline al negociar. Cada
  # evento reinicia este timer y el perfil solo corre cuando la señal lleva
  # treinta segundos estable, evitando cambios de pantalla por falsos contactos
  # breves y que systemd mate un oneshot a medio aplicar.
  systemd.timers.laptop-power-profile-debounce = {
    description = "Debounce de eventos AC del perfil de loon-laptop";
    # Un falso contacto puede generar más eventos que el límite de arranques
    # predeterminado de systemd. El timer debe poder reiniciarse sin quedar en
    # start-limit-hit; el servicio objetivo solo se ejecuta al vencer los 30 s.
    unitConfig.StartLimitIntervalSec = 0;
    timerConfig = {
      OnActiveSec = "30s";
      AccuracySec = "100ms";
      Unit = "laptop-power-profile.service";
    };
  };

  # ACPI emite eventos ac_adapter al conectar o retirar el cargador; el timer
  # actualiza ambas mitades sin sondeo periódico una vez estabilizada la señal.
  services.acpid = {
    enable = true;
    logEvents = true;
    acEventCommands =
      "${systemctl} --no-block restart laptop-power-profile-debounce.timer";
  };

  # El modo temporal explícito de Moonlight conserva prioridad. Al terminar,
  # se reaplica la política AC/batería real y luego se actualiza la sesión.
  systemd.services.moonlight-power-root.serviceConfig.ExecStopPost =
    "${systemctl} restart laptop-power-profile.service";
}
