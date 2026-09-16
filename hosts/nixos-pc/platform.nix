# Plataforma exclusiva de nixos-pc.
{ lib, pkgs, ... }:

let
  ddcBrightness = pkgs.callPackage ../../pkgs/ddc-brightness {
    monitorModel = "GM3CC236";
  };
in
{
  # Lanzaboote reemplaza al módulo systemd-boot y firma toda la cadena de
  # arranque. En el primer switch permite instalar sin firma, genera las claves
  # bajo /var/lib/sbctl y los switches posteriores instalan artefactos firmados.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    autoGenerateKeys.enable = true;
    # La ESP es de 196 MiB; conservar rollbacks suficientes sin saturarla con
    # initrds de generaciones antiguas.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Conserva un menú breve para seleccionar generaciones de recuperación; el
  # resto de hosts mantiene el arranque directo definido por el módulo común.
  boot.loader.timeout = 5;
  # El UEFI de la B550 conserva un modo de baja resolución que el monitor
  # escala y muestra agrandado. Usar el modo GOP máximo corrige el menú.
  boot.loader.systemd-boot.consoleMode = "max";

  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;

  # Swap comprimida en RAM: evita que picos transitorios de Electron, OBS o
  # evaluaciones de Nix degraden la sesión. El límite es lógico y zram solo
  # consume memoria física conforme se usa, aplicando compresión zstd.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  # Los monitores externos no exponen /sys/class/backlight. DDC/CI viaja por
  # los buses I2C de la NVIDIA; este backend controla el monitor principal
  # GM3CC236 conectado a DP-2 y alimenta el indicador de Waybar.
  hardware.i2c.enable = true;
  users.users.loonbac.extraGroups = [ "i2c" ];
  environment.systemPackages = [
    # Diagnóstico, verificación y enrolamiento manual de Secure Boot.
    pkgs.sbctl
    pkgs.ddcutil
    ddcBrightness
  ];

  # Un único proceso conserva el estado, agrupa ráfagas de input y evita que
  # cada paso de la rueda bloquee esperando varios intercambios DDC.
  systemd.user.services.ddc-brightness = {
    description = "Control de brillo DDC/CI del monitor principal";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session-pre.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${ddcBrightness}/bin/ddc-brightness daemon";
      Restart = "on-failure";
      RestartSec = "1s";
      RuntimeDirectory = "ddc-brightness";
      RuntimeDirectoryMode = "0700";
    };
  };

  # La RTX 3060 usa el módulo de kernel propietario de NVIDIA: libfunnel
  # necesita sus capacidades DRM de sincronización explícita para PipeWire.
  # NixOS incorpora también nvidia-smi al PATH del sistema.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
  };
}
