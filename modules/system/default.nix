# Módulo "system": boot, zona horaria, locale, paquetes globales y
# política de paquetes. Una sola responsabilidad, bien aislada.
{ config, lib, pkgs, zen-browser, vscode-insiders, antigravity-cli, ... }:
{
  imports = [
    ./extras-disk.nix
  ];
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

  # ---- Configuración de Nix (Flakes y CLI moderno) ----
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---- Compatibilidad FHS para scripts de Node/npm (ej. gentle-pi busca /bin/tar y /usr/bin/tar) ----
  services.envfs.enable = true;
  systemd.tmpfiles.rules = [
    "L+ /bin/tar - - - - ${pkgs.gnutar}/bin/tar"
    "L+ /usr/bin/tar - - - - ${pkgs.gnutar}/bin/tar"
  ];

  # ---- Keyring del sistema (requisito de Settings Sync de VS Code) ----
  # Sin un Secret Service (org.freedesktop.secrets) en el bus de sesión,
  # VS Code no puede guardar el token de sincronización y Settings Sync
  # falla con "Cannot write to Keychain". Niri no levanta gnome-keyring
  # automáticamente, así que lo declaramos explícitamente.
  services.gnome.gnome-keyring.enable = true;

  # ---- Modo oscuro global ----
  # Las apps GTK abren en dark por defecto (Nautilus, loon-bar, etc.).
  programs.dconf.enable = true;
  programs.dconf.profiles."user".databases = [
    {
      settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          gtk-theme = "Adwaita-dark";
          gtk-application-prefer-dark-theme = true;
        };
      };
    }
  ];

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

  # ---- Variables de entorno de build (Rust/C/C++) ----
  # En NixOS los .pc de openssl/libpq viven en outputs -dev del store; sin
  # PKG_CONFIG_PATH los crates nativos (openssl-sys, pq-sys) no los encuentran.
  # LD_LIBRARY_PATH es para que los binarios encuentren libssl.so en runtime.
  # ---- Variables de entorno de build y sesión ----
  environment.sessionVariables = {
    PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.libpq.dev}/lib/pkgconfig";
    LD_LIBRARY_PATH = "${pkgs.openssl.out}/lib:${pkgs.libpq.out}/lib";
    BROWSER = "zen-browser";
  };

  # ---- Navegador por defecto global (Zen Browser) ----
  xdg.mime = {
    enable = true;
    defaultApplications = {
      "text/html" = "zen.desktop";
      "x-scheme-handler/http" = "zen.desktop";
      "x-scheme-handler/https" = "zen.desktop";
      "x-scheme-handler/about" = "zen.desktop";
      "x-scheme-handler/unknown" = "zen.desktop";
      "application/x-extension-htm" = "zen.desktop";
      "application/x-extension-html" = "zen.desktop";
      "application/x-extension-shtml" = "zen.desktop";
      "application/xhtml+xml" = "zen.desktop";
      "application/x-extension-xhtml" = "zen.desktop";
      "application/x-extension-xht" = "zen.desktop";
    };
  };

  # Permite ejecutar binarios instalados con `npm install -g --prefix ~/.npm-global <pkg>`
  environment.extraInit = ''
    export PATH="$HOME/.npm-global/bin:$PATH"
  '';

  # ---- Paquetes instalados a nivel de sistema ----
  environment.systemPackages = with pkgs; [
    # Agrega aquí paquetes globales: `nix search nixos <paquete>` para encontrar.
    git
    gh
    btop
    bat                # alternativa moderna a cat con resaltado de sintaxis
    poppler-utils      # pdftotext, pdfinfo, etc.
    python3            # intérprete de Python
    uv                 # gestor de Python (venv + paquetes)
    fastfetch
    ghostty
    nodejs
    pnpm
    go
    gcc
    cargo              # toolchain Rust: compila loon-launch, loon-bar, etc.
    rustc
    rustfmt            # componente fmt (cargo fmt)
    clippy             # componente clippy (lints)
    pkg-config         # detección de libs nativas (openssl, libpq) en builds Rust
    openssl            # deps de openssl-sys (mdm-gestor usa jsonwebtoken/sqlx)
    openssl.dev        # .pc files de OpenSSL para pkg-config en builds Rust
    libpq              # deps de pq-sys (sqlx + postgres)
    claude-code
    brightnessctl
    zen-browser
    chromium           # para E2E (Playwright/Puppeteer) en esta máquina
    vscode-insiders
    antigravity
    antigravity-cli
    pi-coding-agent
    obs-studio
    zoom-us
    fish
    psmisc             # killall, pstree, fuser
    yazi
    # Navegación con wrap entre workspaces (Super+Left/Right).
    (pkgs.callPackage ../../pkgs/niri-cycle { })
    # App launcher custom del flake (Super+Space en niri).
    (pkgs.callPackage ../../pkgs/loon-launch { })
    # Comando custom del flake: `rebuild` reconstruye esta config.
    (import ../../pkgs/rebuild { inherit pkgs lib; })

    # Fondo de pantalla animado (video en loop detrás de las ventanas).
    mpvpaper
    mpv
    # Acento dinámico: extrae el color del wallpaper para niri/loon-bar.
    (pkgs.callPackage ../../pkgs/accent-wallpaper { })
    ffmpeg
    imagemagick
    # Script para gestionar el fondo animado (Super+B en niri).
    (pkgs.callPackage ../../pkgs/mpvpaper-wallpaper {
      accent-wallpaper = pkgs.callPackage ../../pkgs/accent-wallpaper { };
    })
    # Script para el fondo estático del backdrop (swaybg, ve a través).
    (pkgs.callPackage ../../pkgs/niri-backdrop { })
    # Prompt personalizado para fish (oh-my-posh).
    oh-my-posh
    # Portapapeles Wayland persistente: sin esto, el contenido se pierde al
    # cerrar la app dueña (p. ej. la UI de captura de niri). wl-clip-persist
    # mantiene el contenido cuando el dueño desaparece.
    wl-clipboard
    wl-clip-persist
    cliphist
    fuzzel             # picker del historial de portapapeles (Super+Shift+V)
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
