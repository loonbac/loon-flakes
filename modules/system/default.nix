# Módulo "system": boot, zona horaria, locale, paquetes globales y
# política de paquetes. Una sola responsabilidad, bien aislada.
{ config, lib, pkgs, zen-browser, vscode-insiders, ... }:

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

  # ---- Fuentes del sistema (Nerd Fonts y FontAwesome para Waybar) ----
  fonts.packages = with pkgs; [
    nerd-fonts.symbols-only
    nerd-fonts.fira-code
    font-awesome
  ];

  # ---- Brillo de pantalla ----
  # Wrapper setuid para que brightnessctl (teclas Fn+F6/F7) pueda escribir
  # en /sys/class/backlight sin pedir contraseña. Solo el binario setuid,
  # no todo el paquete.
  security.wrappers.brightnessctl = {
    owner = "root";
    group = "root";
    setuid = true;
    source = "${pkgs.brightnessctl}/bin/brightnessctl";
  };

  # ---- Paquetes instalados a nivel de sistema ----
  environment.systemPackages = with pkgs; [
    # Agrega aquí paquetes globales: `nix search nixos <paquete>` para encontrar.
    git
    gh
    btop
    fastfetch
    ghostty
    nodejs
    brightnessctl
    zen-browser
    vscode-insiders
    antigravity
    fish
    psmisc             # killall, pstree, fuser
    yazi
    # Navegación con wrap entre workspaces (Super+Left/Right).
    (pkgs.callPackage ../../pkgs/niri-cycle { })
    # App launcher custom del flake (Super+Space en niri).
    (pkgs.callPackage ../../pkgs/loon-launch { })
    # Barra de tareas nativa custom (estilo Windows 10 con IPC niri).
    (pkgs.callPackage ../../pkgs/loon-bar { })
    # Comando custom del flake: `rebuild` reconstruye esta config.
    (import ../../pkgs/rebuild { inherit pkgs lib; })

    # Fondo de pantalla animado (video en loop detrás de las ventanas).
    mpvpaper
    mpv
    # Script para gestionar el fondo animado (Super+B en niri).
    (pkgs.callPackage ../../pkgs/mpvpaper-wallpaper { })
    # Script para el fondo estático del backdrop (swaybg, ve a través).
    (pkgs.callPackage ../../pkgs/niri-backdrop { })
    # Prompt personalizado para fish (oh-my-posh).
    oh-my-posh
    # Tema de cursor por defecto: Win11OSX (Xcursor nativo, compatible Linux).
    (pkgs.callPackage ../../pkgs/win11osx-cursor { })
    # Tema de cursor Vision (blanco/negro) — alternativa.
    (pkgs.callPackage ../../pkgs/vision-cursor { }).white

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
