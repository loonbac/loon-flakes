# Plataforma exclusiva de saitina.
#
# Hardware detectado (2026-11-07):
#   - Placa: MSI PRO B550M-P (MS-7C95)
#   - CPU:   AMD Ryzen 5 5500 (Zen 3, 6C/12T)
#   - GPU:   NVIDIA GP106 / GeForce GTX 1070 (ASUS, Pascal)
#   - Red:   Realtek RTL8168 + Intel Wireless 7265
#   - Audio: NVIDIA HDA (HDMI) + AMD HD Audio
{ config, lib, pkgs, ... }:

{
  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;

  # Bluetooth de la placa: adaptador Intel 8087:0a2a (hci0).
  # Vive aquí y no en /etc/nixos: ese archivo no tiene escritorio y un switch
  # con él mata la sesión gráfica (pasó el 2026-11-07 a las 17:37).
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Acceso a /dev/hidraw de los Joy-Con para Eglantine (fork de Yuzu/Eden).
  #
  # Su "joycon driver" (enable_joycon_driver=true) abre el mando por hidraw en
  # vez de por /dev/input, y hidraw nace 0600 root: sin esta regla el log
  # repite "Yuzu can't gain access to this device: ID 057E:2006/2007" y el
  # emulador no lista los mandos. Ryujinx sí los ve sin nada extra porque usa
  # el motor SDL, que lee /dev/input/js* (con uaccess desde 70-uaccess.rules).
  #
  # Via Bluetooth el Joy-Con no es un dispositivo USB: es un uhid virtual
  # creado por hidp, sin idVendor/idProduct en sysfs (por eso no sirve
  # ATTRS{idVendor}). Su DEVPATH sí lleva el identificador, y el HID padre
  # expone modalias, así que se matchea por DEVPATH.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", DEVPATH=="*057E:2006*", MODE="0660", GROUP="input", TAG+="uaccess"
    KERNEL=="hidraw*", DEVPATH=="*057E:2007*", MODE="0660", GROUP="input", TAG+="uaccess"
  '';

  # GTX 1070 = Pascal. Los módulos abiertos de NVIDIA solo cubren Turing en
  # adelante, así que el driver propietario es el único válido aquí.
  # modesetting habilita KMS, necesario para niri sobre Wayland.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
    # La rama 595 ya no soporta Pascal. legacy_580 es la última que sí
    # (Maxwell/Pascal/Volta) y la que corresponde a la GTX 1070.
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
  };

  # Swap comprimida en RAM: el equipo no tiene partición swap.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  # No hay panel interno: el brillo por sysfs no aplica. Dejar el comando en
  # null hace que waybar omita el módulo y que niri no inyecte binds de brillo.
  hardware.brightness.backend = "internal";
  hardware.brightness.command = null;

  # Bus I2C de la NVIDIA (DDC/CI para el monitor externo).
  hardware.i2c.enable = true;

  # Render de escritorio sin caídas de reloj.
  powerManagement.cpuFreqGovernor = "performance";
}
