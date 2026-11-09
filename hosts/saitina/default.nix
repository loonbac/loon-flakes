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

  # GUI de Bluetooth: blueman (manager para emparejar/conectar + applet en la
  # bandeja de Waybar, que es quien registra el agente de BlueZ). El servicio
  # de usuario del applet vive en modules/wayland/niri/session-services.nix
  # y solo arranca si esta opción está activa.
  services.blueman.enable = true;

  # La barra ya tiene el módulo nativo `bluetooth` a la derecha (con
  # on-click → blueman-manager), que es el que se usa. El icono que el applet
  # pone en el `tray` (izquierda) duplica esa función, así que se deshabilita.
  #
  # Hay que apagar ShowConnected además de StatusIcon: ShowConnected depende
  # de StatusIcon y su carga lo arrastraría de vuelta aunque esté en la lista.
  # Ambos siguen siendo unloadable (ningún plugin no-descargable depende de
  # ellos), y PowerManager/KillSwitch ya guardan con "StatusIcon in
  # get_loaded()", así que nada más se rompe.
  #
  # Va como default del file-db de dconf: el user-db va primero en el profile,
  # así que si algún día se cambia un plugin desde el diálogo de Blueman, esa
  # elección propia pisa este default (dconf no fusiona arrays).
  programs.dconf.profiles."user".databases = [
    {
      settings = {
        "org/blueman/general" = {
          plugin-list = [
            "!ShowConnected"
            "!StatusIcon"
          ];
        };
      };
    }
  ];

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
  # El navegador por defecto es Helium; Firefox está declarado en
  # modules/system/packages.nix, sin capturar BROWSER ni MIME.
  environment.systemPackages = with pkgs; [
    nautilus
    gnome-disk-utility
    ntfs3g
  ];

  # Soporte para sistemas de archivos NTFS (discos secundarios y Windows).
  boot.supportedFilesystems = [ "ntfs" ];

  # Windows deja los volumenes NTFS "dirty" al apagar sin desmontaje limpio
  # (Inicio rapido) y el driver ntfs3 se niega a montarlos sin `force`: el
  # usuario ve un error generico de "bad superblock" y el disco desaparece.
  # Sin esto, cada sesion de Windows vuelve a dejar HELL (y DATA/NAH) fuera.
  # `force` es opcion del driver ntfs3; la lista allow es la builtin completa
  # mas esa opcion. El volumen del sistema Windows no se automonta (udisks
  # lo marca HintSystem), asi que queda fuera de este camino.
  environment.etc."udisks2/mount_options.conf".text = ''
    [defaults]
    ntfs:ntfs3_defaults=uid=$UID,gid=$GID,force
    ntfs:ntfs3_allow=uid=$UID,gid=$GID,umask,dmask,fmask,iocharset,discard,nodiscard,sparse,nosparse,hidden,nohidden,sys_immutable,nosys_immutable,showmeta,noshowmeta,prealloc,noprealloc,hide_dot_files,nohide_dot_files,windows_names,nocase,case,force
  '';

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

  # Deduplicación del store: reemplaza archivos idénticos por hardlinks.
  # Sin esto (auto-optimise-store=false por defecto) cada paquete que repite
  # un mismo binario o librería paga su copia completa. Semanal, a la par del
  # GC, y con Nice/IO idle de fábrica: no compite con nada.
  nix.optimise = {
    automatic = true;
    dates = "weekly";
  };
}
