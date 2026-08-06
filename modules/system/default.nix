# Módulo "system": boot, zona horaria, locale, paquetes globales y
# política de paquetes. Una sola responsabilidad, bien aislada.
{ config, lib, pkgs, zen-browser, ... }:

{
  # ---- Bootloader (systemd-boot + UEFI) ----
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ---- Zona horaria y localización ----
  time.timeZone = "America/Lima";
  i18n.defaultLocale = "es_PE.UTF-8";

  # Keymap de X11 y consola
  services.xserver.xkb = {
    layout = "es";
    variant = "";
  };
  console.keyMap = "es";

  # ---- Paquetes no libres (ej. microcode Intel) ----
  nixpkgs.config.allowUnfree = true;

  # ---- Paquetes instalados a nivel de sistema ----
  environment.systemPackages = with pkgs; [
    # Agrega aquí paquetes globales: `nix search nixos <paquete>` para encontrar.
    git
    gh
    btop
    fastfetch
    ghostty
    nodejs
    zen-browser
    fish
    # Navegación con wrap entre workspaces (Super+Left/Right).
    (pkgs.callPackage ../../pkgs/niri-cycle { })
    # App launcher custom del flake (Super+Space en niri).
    (pkgs.callPackage ../../pkgs/loon-launch { })
    # Comando custom del flake: `rebuild` reconstruye esta config.
    (import ../../pkgs/rebuild { inherit pkgs lib; })

    # ---- Utilidades de diagnóstico de hardware/drivers ----
    # Para verificar que los drivers (GPU/VA-API, WiFi, etc.) funcionan.
    libva-utils        # vainfo: estado de la aceleración VA-API (GPU Intel)
    pciutils           # lspci: dispositivos PCI (GPU, WiFi, audio)
    usbutils           # lsusb: dispositivos USB
    dmidecode          # información DMI/BIOS del equipo
    inxi               # resumen completo de hardware y sistema
    lshw               # listado detallado de hardware
    iw                 # estado y configuración de interfaces WiFi
  ];
}
