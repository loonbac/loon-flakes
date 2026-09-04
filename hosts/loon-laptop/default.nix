# host "loon-laptop": como `src/main.rs` — solo compone,
# no define lógica. La lógica vive en ../modules.
#
# TODO: los drivers/firmware de este host están aquí abajo y NO en
# ../modules, porque son específicos del hardware de esta laptop
# (Dell Inspiron 15 3520). Otros hosts que usen este flake no deben
# heredarlos.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./power.nix
  ];

  # Identidad del host (análogo al `[package] name` del Cargo.toml).
  networking.hostName = "loon-laptop";
  system.stateVersion = "26.05";

  # ---- Hardware específico de esta laptop (Dell Inspiron 15 3520) ----

  # GPU: Intel Iris Xe (Alder Lake, device 46a8). Ya funciona con i915/xe;
  # habilitamos el stack de gráficos y el driver VA-API (iHD) para
  # aceleración por hardware (video, etc.).
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # VA-API (iHD) para Intel moderno
      vpl-gpu-rt         # runtime oneVPL (QSV) para encode por hardware en OBS
    ];
  };

  # WiFi Realtek 8821CE (rtw88_8821ce), Bluetooth Realtek y microcode
  # Intel: requieren firmware redistribuible que NixOS no incluye por
  # defecto. Sin esto el WiFi no funciona.
  hardware.enableRedistributableFirmware = true;

  # Bluetooth Realtek (RTL8821CE, USB 0bda:c829): habilita el servicio y
  # el soporte del kernel (btusb). Sin esto el adaptador no funciona.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
}
