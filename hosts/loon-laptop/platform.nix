# Plataforma exclusiva del Dell Inspiron 15 3520. No importar globalmente.
{ pkgs, ... }:

{
  imports = [
    ./extras-disk.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 3;
  boot.loader.efi.canTouchEfiVariables = true;

  # Hibernación. La partición de swap (16.8 G) supera la RAM (15.3 G), así que
  # el equipo puede congelar la imagen en disco. Declarar el dispositivo hace
  # que NixOS añada `resume=` al cmdline (`systemd/initrd.nix:534`); sin esa
  # marca el kernel no sabe de dónde restaurar y el sistema se apagaría sin
  # recuperar la sesión. `loon-launch` exige las tres condiciones —`resume=`,
  # swap no-zram y tamaño ≥ RAM— para ofrecer «Hibernar» en el menú de poder.
  # nixos-pc no lo declara: solo tiene zram, que es volátil, y no puede hibernar.
  boot.resumeDevice = "/dev/disk/by-uuid/bbb1deac-4592-4631-88d5-0f307639ff3b";

  # Early KMS de Intel para que Plymouth use la resolución nativa.
  boot.initrd.kernelModules = [ "i915" ];

  # Al bajar la tapa, hypridle bloquea la sesión y logind suspende el equipo.
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
  };

  # Intel Iris Xe (Alder Lake): VA-API iHD y oneVPL/QSV.
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
    ];
  };
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  hardware.brightness.backend = "internal";

  # Configuración inicial de salida para niri (panel integrado eDP-1).
  programs.niri.defaultMonitorConfig = ''
    // Valor inicial; nwg-displays puede reemplazar este archivo.
    output "eDP-1" {
        hot-corners {
            off
        }
    }
  '';

  # Control exclusivo del panel interno Intel de este Dell. El wrapper
  # permite que las teclas Fn cambien /sys/class/backlight sin contraseña;
  # el paquete screen-brightness lo provee el módulo de brillo unificado.
  environment.systemPackages = [
    pkgs.brightnessctl
  ];
  security.wrappers.brightnessctl = {
    owner = "root";
    group = "root";
    setuid = true;
    source = "${pkgs.brightnessctl}/bin/brightnessctl";
  };

  # Firmware del WiFi/Bluetooth Realtek y microcode Intel.
  hardware.enableRedistributableFirmware = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
}
