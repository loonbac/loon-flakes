# Host "saitina": MSI PRO B550M-P + Ryzen 5 5500 + GeForce GTX 1070.
# Dual boot Windows + NixOS. Solo compone; la lógica vive en ../../modules.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./platform.nix
  ];

  networking.hostName = "saitina";
  system.stateVersion = "26.05";

  # ------------------------------------------------------------- identidad
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";
  services.xserver.xkb.layout = "us";
  time.timeZone = "America/Argentina/Buenos_Aires";
  # Windows guarda el RTC en hora local.
  time.hardwareClockInLocalTime = true;

  # -------------------------------------------------------------- arranque
  # GRUB EFI sobre la ESP propia (nvme0n1p5). Windows tiene su PROPIA ESP
  # (nvme0n1p4), así que la entrada se declara por UUID en vez de os-prober.
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    device = "nodev";
    configurationLimit = 3;
    useOSProber = false;
    extraEntries = ''
      menuentry "Windows Boot Manager" --class windows --class os {
        insmod part_gpt
        insmod fat
        insmod chain
        search --no-floppy --fs-uuid --set=root D249-0B70
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      }
    '';
  };
  boot.loader.timeout = 10;

  # FAT32 no tiene permisos POSIX: sintetizarlos restrictivos.
  fileSystems."/boot".options = lib.mkForce [ "umask=0077" ];

  # ---------------------------------------------------------------- sesión
  # Login gráfico mínimo con tuigreet sobre niri. Deja el escritorio usable
  # desde el primer arranque; el greeter DMS del repo se puede sumar después.
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${config.programs.niri.package}/bin/niri-session";
      user = "greeter";
    };
  };

  # Audio: los binds de niri usan wpctl.
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # El módulo de Equibop trae un servicio para el Razer Basilisk V3 del equipo
  # original (F13 → mute). Este host usa otro mouse: la unidad queda fuera.
  systemd.services.equibop-basilisk-mic-hotkey.enable = false;

  # Máquina de escritorio: no pausar el fondo animado detrás de ventanas opacas
  # (mantiene el video siempre en movimiento independientemente de las ventanas).
  systemd.user.services.niri-wallpaper-visibility.enable = false;

  # Compartir pantalla: programs.niri (nixpkgs) apunta ScreenCast al backend
  # gnome, que en niri no completa la negociación con PipeWire y el reparto se
  # rompe en apps WebRTC (Discord/Equibop, Meet). Este host sí expone
  # wlr-screencopy (verificado con grim), así que ScreenCast va al backend wlr;
  # la elección de monitor/ventana la hace el chooser de fuzzel.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-wlr ];
    config.niri."org.freedesktop.impl.portal.ScreenCast" = "wlr";
  };

  # Explorador de archivos (Super+E), utilidad de discos NTFS y navegador.
  programs.firefox.enable = true;
  environment.systemPackages = with pkgs; [
    nautilus
    gnome-disk-utility
    ntfs3g
  ];

  # Soporte para sistemas de archivos NTFS (discos secundarios y Windows).
  boot.supportedFilesystems = [ "ntfs" ];

  # PORT compila los plugins en un árbol temporal y el [patch] del repo de
  # plugins apunta a `../port`: desde /tmp eso resuelve a /tmp/port. El clon
  # del código (tag v0.1.5, el que fija el workspace de plugins) vive en el
  # home y este enlace lo recrea en cada arranque; sin él, `port plugin add`
  # falla con "failed to load source for dependency port-plugin-api".
  systemd.tmpfiles.rules = [
    "L+ /tmp/port - - - - /home/saito/.local/share/port-sdk/port"
  ];

  # --------------------------------------------------------------- limpieza
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
