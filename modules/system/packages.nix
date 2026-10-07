# Módulo "system/packages": catálogo de paquetes instalados a nivel de sistema
# y los runtimes de desarrollo que consumen. No define configuración del
# sistema: solo qué software global está disponible.
{ lib, pkgs, zen-browser, helium-browser, vscode-insiders, antigravity-cli, port, ... }:
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

  # Runtimes y outputs de desarrollo requeridos por Tauri/WebKitGTK. Los
  # outputs dev aportan los headers y archivos .pc que consulta pkg-config.
  tauriPackages = with pkgs; [
    webkitgtk_4_1
    gtk3
    libsoup_3
    glib
    cairo
    pango
    gdk-pixbuf
    atk
    librsvg
    dbus
    wayland
    libxkbcommon
    libayatana-appindicator
    glib-networking
    gsettings-desktop-schemas
    libglvnd
    mesa
    libx11
    libxcursor
    libxi
    libxrandr
    libxext
    libxfixes
    libxcomposite
    libxdamage
    libxrender
  ];
  tauriDevelopmentPackages = map lib.getDev (lib.closePropagation tauriPackages);
in
{
  # ---- Paquetes instalados a nivel de sistema ----
  environment.systemPackages = with pkgs; [
    # Agrega aquí paquetes globales: `nix search nixos <paquete>` para encontrar.
    git
    gh
    btop
    bat                # alternativa moderna a cat con resaltado de sintaxis
    libsecret          # secret-tool CLI para apps que usan Secret Service (ej. andes CLI)
    poppler-utils      # pdftotext, pdfinfo, etc.
    pandoc             # conversión entre Markdown, HTML, PDF y DOCX
    wkhtmltopdf        # motor HTML-a-PDF usado por pandoc con --pdf-engine
    python3            # intérprete de Python
    uv                 # gestor de Python (venv + paquetes)
    fastfetch
    ghostty
    # PORT: terminal con GPUI y sistema de plugins. Llega ya resuelto desde
    # `specialArgs`, como el resto de paquetes externos del flake.
    port
    nodejs
    pnpm
    bubblewrap         # sandbox Linux usado por Codex (`bwrap` en PATH)
    jq                 # requisito de codex-advisor
    ripgrep            # requisito de codex-advisor (`rg`)
    go
    gnumake            # comando `make`
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
    helium-browser
    chromium           # para E2E (Playwright/Puppeteer) en esta máquina
    vscode-insiders
    antigravity
    antigravity-cli
    grok-cli
    codexLatest
    (pkgs.callPackage ../../pkgs/cline-launcher { })
    zoom-us
    prismlauncher
    # Moonlight: cliente de streaming remoto (Sunshine/GameStream) para
    # ver y controlar el PC desde otros dispositivos.
    moonlight-qt
    # ONLYOFFICE: usa el X11 display :0 del xwayland-satellite nativo de niri
    # (su Qt embebido no soporta Wayland; niri exporta DISPLAY=:0 a la sesión).
    # El paquete original trae su .desktop para que aparezca en loon-launch.
    onlyoffice-desktopeditors
    notepad-next      # editor de texto gráfico multiplataforma
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

    # ---- Utilidades de diagnóstico de hardware/drivers ----
    # Para verificar que los drivers (GPU/VA-API, WiFi, etc.) funcionan.
    libva-utils        # vainfo: estado de la aceleración VA-API (GPU Intel)
    pciutils           # lspci: dispositivos PCI (GPU, WiFi, audio)
    usbutils           # lsusb: dispositivos USB
    dmidecode          # información DMI/BIOS del equipo
    inxi               # resumen completo de hardware y sistema
    lshw               # listado detallado de hardware
    iw                 # estado y configuración de interfaces WiFi
  ] ++ tauriPackages ++ tauriDevelopmentPackages;
}
