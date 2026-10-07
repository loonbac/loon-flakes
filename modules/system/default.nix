# Módulo "system": arranque, zona horaria, locale, keymap, servicios base de
# sesión y política de paquetes. Los paquetes globales viven en
# `packages.nix` y la presentación del sistema (fuentes, modo oscuro y
# asociaciones MIME) en `theme.nix`.
{ config, lib, pkgs, ... }:
{
  # OJO con el orden de esta lista: `lib/modules.nix` recolecta los módulos
  # por niveles y después invierte la lista (`reverseList (doCollect {}).modules`),
  # así que el orden efectivo de las definiciones —el que decide el resultado
  # del merge de opciones de lista, como `environment.systemPackages`— es el
  # INVERSO de esta lista, y el cuerpo del módulo queda al final.
  #
  # Por eso los módulos se declaran en orden inverso al deseado: se conserva
  # exactamente el mismo orden de merge que cuando `default.nix` definía todo
  # en un solo archivo (coredump → brightness → plymouth → paquetes → tema),
  # de modo que el `drvPath` del sistema no cambia con esta división.
  imports = [
    ./theme.nix
    ./packages.nix
    ./plymouth.nix
    ./brightness.nix
    ./coredump.nix
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

  # ---- Compatibilidad FHS para scripts de Node/npm (ej. gentle-pi busca /bin/tar, cline busca /bin/bash) ----
  systemd.tmpfiles.rules = [
    "L+ /bin/tar - - - - ${pkgs.gnutar}/bin/tar"
    "L+ /usr/bin/tar - - - - ${pkgs.gnutar}/bin/tar"
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    "L+ /usr/bin/bash - - - - ${pkgs.bash}/bin/bash"
  ];

  # ---- Keyring del sistema (requisito de Settings Sync de VS Code) ----
  # Sin un Secret Service (org.freedesktop.secrets) en el bus de sesión,
  # VS Code no puede guardar el token de sincronización y Settings Sync
  # falla con "Cannot write to Keychain". Niri no levanta gnome-keyring
  # automáticamente, así que lo declaramos explícitamente.
  services.gnome.gnome-keyring.enable = true;

  # ---- Servicio dconf ----
  # Infraestructura, no presentación: los perfiles de dconf (modo oscuro en
  # `theme.nix`, iconos en `programs/gtk`) necesitan el daemon habilitado.
  programs.dconf.enable = true;

  # ---- Variables de entorno de build y sesión ----
  environment.sessionVariables = {
    PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.libpq.dev}/lib/pkgconfig:/run/current-system/sw/lib/pkgconfig:/run/current-system/sw/share/pkgconfig";
    LD_LIBRARY_PATH = "${pkgs.openssl.out}/lib:${pkgs.libpq.out}/lib";
    SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    SSL_CERT_DIR = "/etc/ssl/certs";
    BROWSER = "zen-browser";
    NPM_CONFIG_PREFIX = "/home/loonbac/.npm-global";
  };

  # Permite ejecutar binarios instalados con `npm install -g --prefix ~/.npm-global <pkg>`
  environment.extraInit = ''
    export PATH="$PATH:$HOME/.npm-global/bin"
  '';

  # Publica los metadatos de desarrollo de los paquetes Tauri en la ruta del
  # sistema; sus .pc conservan las rutas exactas del store para headers/libs.
  environment.pathsToLink = [ "/lib/pkgconfig" "/share/pkgconfig" ];

  # Un proceso root (sudo nixos-rebuild, o la unidad desacoplada de `rebuild`)
  # debe poder evaluar el flake del usuario: libgit2 rechaza un repositorio git
  # cuyo dueño no es el usuario efectivo, y no respeta las variables
  # GIT_CONFIG_*; esta entrada lo habilita explícitamente sin perder la
  # semántica git (solo archivos trackeados).
  environment.etc."gitconfig".text = ''
    [safe]
    	directory = /home/loonbac/.nixos
  '';
}
