# Módulo "system/packages": catálogo de paquetes instalados a nivel de sistema.
# Base de apariencia (niri, barra, lock, wallpapers) + herramientas de trabajo.
# No define configuración del sistema: solo qué software global está disponible.
{ lib, pkgs, loonLaunch, port, antigravity-cli, helium-browser, opencode, ... }:

let
  accentWallpaper = pkgs.callPackage ../../pkgs/accent-wallpaper { };
  mpvpaperWallpaper = pkgs.callPackage ../../pkgs/mpvpaper-wallpaper {
    accent-wallpaper = accentWallpaper;
  };
in
{
  environment.systemPackages = with pkgs; [
    # ---- Base del sistema ----
    git
    gh
    curl
    wget
    btop
    bat
    fastfetch
    psmisc
    jq
    ripgrep
    unzip
    file

    # ---- Terminal y shell ----
    ghostty
    oh-my-posh
    # PORT: terminal con GPUI y sistema de plugins, desde su flake (specialArg).
    port

    # ---- Agentes / IA ----
    # OpenCode V2 llega por specialArgs desde el input nixpkgs-unstable (el
    # canal del sistema todavía no publica la 2.x). Canal móvil, sin pin: lo
    # actualiza `nix flake update nixpkgs-unstable` + `rebuild`.
    opencode
    # CLI de Antigravity desde el input antigravity-nix.
    antigravity-cli

    # ---- Navegadores ----
    # Helium llega del flake (input helium-browser) sin versión fijada.
    # Es el navegador por defecto: BROWSER (modules/system/default.nix) y las
    # asociaciones MIME (modules/system/theme.nix) apuntan a helium.desktop.
    # Firefox vuelve declarado (AGENTS.md → "Instalar un paquete"): estaba
    # solo en el perfil de usuario y ningún servicio de sesión lo resolvía
    # ("firefox: command not found" desde loon-launch). No toca BROWSER ni
    # los MIME, así que Helium sigue siendo el default.
    helium-browser
    firefox

    # ---- Editores ----
    # nano es el EDITOR por defecto (EDITAR=y git sin -m); NotepadNext es el
    # editor gráfico. Mismo caso que Firefox: instalado solo en el perfil de
    # usuario, su .desktop no abría desde el launcher.
    notepad-next

    # ---- Comunicación ----
    # equibop lo instala y configura su propio módulo
    # (modules/programs/equibop). El cliente oficial `discord` se retiró:
    # eran dos clientes Discord simultáneos y sumaba ~600M al cierre.

    # ---- Escritorio niri ----
    # waybar, swaync, hyprlock e hypridle los instala su propio módulo.
    nwg-displays
    nautilus
    xwayland-satellite

    # ---- Wallpapers y acento dinámico ----
    mpvpaper
    mpv
    ffmpeg
    imagemagick
    awww
    fuzzel
    wl-clipboard
    wl-clip-persist
    cliphist
    (pkgs.callPackage ../../pkgs/niri-cycle { })
    accentWallpaper
    mpvpaperWallpaper
    (pkgs.callPackage ../../pkgs/niri-backdrop {
      accent-wallpaper = accentWallpaper;
    })
    (pkgs.callPackage ../../pkgs/niri-wallpaper-visibility {
      inherit mpvpaperWallpaper;
    })
    (pkgs.callPackage ../../pkgs/win11osx-cursor { })

    # ---- Piezas propias del flake ----
    loonLaunch
    (import ../../pkgs/rebuild { inherit pkgs lib; })
    (pkgs.callPackage ../../pkgs/nixos-updates { })

    # ---- Desarrollo ----
    nodejs
    pnpm
    go
    gnumake
    gcc
    pkg-config
    openssl
    openssl.dev
    libpq
    python3
    uv

    # ---- Diagnóstico de hardware ----
    pciutils
    usbutils
    dmidecode
    inxi
    lshw
    libva-utils
  ];
}
