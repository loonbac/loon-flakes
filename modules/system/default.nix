# Módulo "system": boot, zona horaria, locale, paquetes globales y
# política de paquetes. Una sola responsabilidad, bien aislada.
{ config, lib, pkgs, zen-browser, vscode-insiders, antigravity-cli, ... }:
let
  codexLatest = pkgs.writeShellApplication {
    name = "codex";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      npm_prefix="$HOME/.npm-global"
      codex_bin="$npm_prefix/bin/codex"

      # No actualices la instalación global en cada arranque: reemplazar sus
      # archivos mientras otra sesión está abierta puede retirar temporalmente
      # binarios auxiliares como codex-code-mode-host.
      if [ ! -x "$codex_bin" ]; then
        if ! npm install --global --prefix "$npm_prefix" \
          --no-audit --no-fund --loglevel=error @openai/codex@latest >/dev/null; then
          echo "codex: failed to install @openai/codex@latest" >&2
          exit 1
        fi
      fi

      exec "$codex_bin" "$@"
    '';
  };

  # Packet Tracer depende de un instalador propietario aportado manualmente
  # al store de la laptop. No bloquear hosts nuevos que no poseen ese archivo.
  packetTracerPackages = lib.optionals
    (builtins.elem config.networking.hostName [ "loon-laptop" "korosoft" ])
    [ (pkgs.callPackage ../../pkgs/cisco-packet-tracer { }) ];
in
{
  imports = [
    ./plymouth.nix
  ];

  # ---- Zona horaria y localización ----
  time.timeZone = "America/Lima";
  i18n.defaultLocale = "es_PE.UTF-8";
  i18n.supportedLocales = [
    "C.UTF-8/UTF-8"
    "en_US.UTF-8/UTF-8"
    "es_PE.UTF-8/UTF-8"
    "es_ES.UTF-8/UTF-8"
  ];

  # Keymap de X11 y consola
  services.xserver.xkb = {
    # Los hosts con teclado físico distinto pueden sobrescribir este valor.
    layout = lib.mkDefault "es";
    variant = "";
  };
  console.keyMap = lib.mkDefault "es";

  # ---- Paquetes no libres (ej. microcode Intel) ----
  nixpkgs.config.allowUnfree = true;

  # ---- Configuración de Nix (Flakes y CLI moderno) ----
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---- Compatibilidad FHS para scripts de Node/npm (ej. gentle-pi busca /bin/tar y /usr/bin/tar) ----
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
    nerd-fonts.jetbrains-mono
    font-awesome
  ];

  # ---- Variables de entorno de build y sesión ----
  environment.sessionVariables = {
    PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.libpq.dev}/lib/pkgconfig";
    LD_LIBRARY_PATH = "${pkgs.openssl.out}/lib:${pkgs.libpq.out}/lib";
    BROWSER = "zen-browser";
    NPM_CONFIG_PREFIX = "/home/loonbac/.npm-global";
  };

  # ---- Navegador por defecto global (Zen Browser) ----
  xdg.mime = {
    enable = true;
    defaultApplications = {
      "text/html" = "zen.desktop";
      "x-scheme-handler/http" = "zen.desktop";
      "x-scheme-handler/https" = "zen.desktop";
      "x-scheme-handler/chrome" = "zen.desktop";
      "x-scheme-handler/about" = "zen.desktop";
      "x-scheme-handler/unknown" = "zen.desktop";
      "application/pdf" = "zen.desktop";
      "application/json" = "zen.desktop";
      "text/xml" = "zen.desktop";
      "application/xml" = "zen.desktop";
      "application/xhtml+xml" = "zen.desktop";
      "application/x-extension-htm" = "zen.desktop";
      "application/x-extension-html" = "zen.desktop";
      "application/x-extension-shtml" = "zen.desktop";
      "application/x-extension-xhtml" = "zen.desktop";
      "application/x-extension-xht" = "zen.desktop";
      "image/svg+xml" = "zen.desktop";
      "image/webp" = "zen.desktop";
      "application/vnd.mozilla.xul+xml" = "zen.desktop";
    };
  };

  # Permite ejecutar binarios instalados con `npm install -g --prefix ~/.npm-global <pkg>`
  environment.extraInit = ''
    export PATH="$PATH:$HOME/.npm-global/bin"
  '';

  # ---- Paquetes instalados a nivel de sistema ----
  environment.systemPackages = with pkgs; [
    # Agrega aquí paquetes globales: `nix search nixos <paquete>` para encontrar.
    git
    gh
    btop
    bat                # alternativa moderna a cat con resaltado de sintaxis
    poppler-utils      # pdftotext, pdfinfo, etc.
    pandoc             # conversión entre Markdown, HTML, PDF y DOCX
    wkhtmltopdf        # motor HTML-a-PDF usado por pandoc con --pdf-engine
    python3            # intérprete de Python
    uv                 # gestor de Python (venv + paquetes)
    fastfetch
    ghostty
    nodejs
    pnpm
    bubblewrap         # sandbox Linux usado por Codex (`bwrap` en PATH)
    jq                 # requisito de codex-advisor
    ripgrep            # requisito de codex-advisor (`rg`)
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
    zen-browser
    chromium           # para E2E (Playwright/Puppeteer) en esta máquina
    vscode-insiders
    antigravity
    antigravity-cli
    grok-cli
    codexLatest
    zoom-us
    # Orca ADE: distribución oficial Linux AppImage, empaquetada localmente
    # porque nixpkgs solo ofrece el lector de pantalla GNOME homónimo.
    (pkgs.callPackage ../../pkgs/orca { })
    prismlauncher
    # Moonlight: cliente de streaming remoto (Sunshine/GameStream) para
    # ver y controlar el PC desde otros dispositivos.
    moonlight-qt
    # ONLYOFFICE: usa el X11 display :0 del xwayland-satellite nativo de niri
    # (su Qt embebido no soporta Wayland; niri exporta DISPLAY=:0 a la sesión).
    # El paquete original trae su .desktop para que aparezca en loon-launch.
    onlyoffice-desktopeditors
    # XWayland rootless: display X11 para apps que solo soportan X11/Qt-xcb
    # (ONLYOFFICE incluye Qt embebido sin soporte Wayland). niri lo lanza
    # automáticamente (socket activation, display :0) si está en PATH.
    xwayland-satellite
    fish
    psmisc             # killall, pstree, fuser
    lzip               # compresión lz (requisito de waydroid_script)
    yazi
    # Navegación con wrap entre workspaces (Super+Left/Right).
    (pkgs.callPackage ../../pkgs/niri-cycle { })
    # App launcher custom del flake (Super+Space en niri).
    (pkgs.callPackage ../../pkgs/loon-launch { })
    # Comando custom del flake: `rebuild` reconstruye esta config.
    (import ../../pkgs/rebuild { inherit pkgs lib; })
    # Herramienta de diferencia de versiones Nix/NixOS.
    nvd
    # Gestor y comprobador de actualizaciones custom en segundo plano.
    (pkgs.callPackage ../../pkgs/nixos-updates { })
        # Toggle de autenticación SSH: `nixos-ssh` pregunta password/cert
        # y aplica la config (misma lógica que el comando `rebuild`).
        (pkgs.callPackage ../../pkgs/nixos-ssh { })
        # Alertas de batería baja crítica (<=10%)
        libnotify
        (pkgs.callPackage ../../pkgs/battery-notify { })
    # Fondo de pantalla animado (video en loop detrás de las ventanas).
    mpvpaper
    mpv
    # Acento dinámico: extrae el color del wallpaper para niri/loon-bar.
    (pkgs.callPackage ../../pkgs/accent-wallpaper { })
    ffmpeg
    # Separación local de voces con RoFormer/CUDA. Los pesos quedan fuera del
    # store, en ~/Proyectos/separador-vocal/modelos, y se cargan sólo al usarlo.
    (pkgs.callPackage ../../pkgs/karaoke-separator { })
    imagemagick
    # Script para gestionar el fondo animado (Super+B en niri).
    (pkgs.callPackage ../../pkgs/mpvpaper-wallpaper {
      accent-wallpaper = pkgs.callPackage ../../pkgs/accent-wallpaper { };
    })
    # Script para el fondo estático del backdrop (awww, transiciones animadas).
    (pkgs.callPackage ../../pkgs/niri-backdrop {
      accent-wallpaper = pkgs.callPackage ../../pkgs/accent-wallpaper { };
    })
    # Daemon de wallpapers con transiciones animadas (usado por niri-backdrop).
    awww
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
  ] ++ packetTracerPackages;
}
