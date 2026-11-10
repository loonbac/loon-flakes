# Plataforma exclusiva de saitina.
#   Placa: MSI PRO B550M-P (MS-7C95) · CPU: AMD Ryzen 5 5500 (6C/12T)
#   GPU:   NVIDIA GP106 / GeForce GTX 1070 (ASUS, Pascal) · 8 GiB
#   Red:   Realtek RTL8168 (enp42s0) + Intel Wireless 7265 (wlp33s0)
#   Audio: NVIDIA HDA (HDMI) + AMD HD Audio
{ config, lib, pkgs, ... }:

{
  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;

  # Bluetooth de la placa: adaptador Intel 8087:0a2a (hci0).
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # GTX 1070 = Pascal: la rama 595 ya no la soporta, así que el driver
  # propietario es el único válido. modesetting habilita KMS (necesario
  # para niri sobre Wayland).
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
  };

  # El equipo no tiene partición swap: swap comprimida en RAM.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  # Bus I2C de la NVIDIA (DDC/CI para el monitor externo).
  hardware.i2c.enable = true;

  # No hay panel interno: el brillo por sysfs no aplica. Dejar el comando en
  # null hace que waybar omita el módulo y que niri no inyecte binds de brillo
  # (Fn+F6/F7 no tendrían nada que mover en este equipo).
  hardware.brightness.backend = "internal";
  hardware.brightness.command = null;

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

  # La regla de arriba deja los hidraw en 0660 root:input, así que el usuario
  # necesita el grupo para abrirlos. Sin él solo queda el ACL de uaccess, y
  # logind NO lo aplica de forma fiable cada vez que el Joy-Con se reconecta:
  # pasó tres veces (2026-11-09 22:22, 2026-11-10 09:19 y 09:24) y en todas
  # hubo que forzarlo con `udevadm trigger`, con Eglantine fallando
  # "Yuzu can't gain access to this device" mientras SDL veía js0 sin más.
  #
  # Con el grupo, la apertura no depende del ACL y sobrevive a cualquier
  # reconexión. Mismo patrón que hosts/nixos-pc/sunshine.nix.
  #
  # OJO: los grupos nuevos solo se aplican en el próximo login.
  users.users.saito.extraGroups = [ "input" ];

  # Render de escritorio sin caídas de reloj.
  powerManagement.cpuFreqGovernor = "performance";
}
