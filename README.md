# loon-flakes — Configuración modular de NixOS (host: loon-laptop)

Configuración de NixOS organizada con **módulos pequeños, con
responsabilidad única, componibles y declarativos**. Nada de monolitos.

```
~/.nixos/
├── flake.nix                          # "Cargo.toml" del sistema (inputs + paquetes)
├── flake.lock                         # lockfile versionado (no tocar a mano)
├── AGENTS.md                          # guía para agentes que trabajan la config
├── README.md                          # este archivo
├── pkgs/                              # "binarios" propios del flake
│   ├── rebuild/                       # comando custom `rebuild`
│   ├── loon-launch/                   # app launcher GTK4 (Super+Space)
│   ├── niri-cycle/                    # mover ventanas con wrap infinito
│   ├── mpvpaper-wallpaper/            # fondo animado (video en loop)
│   ├── niri-backdrop/                 # fondo estático del backdrop
│   ├── gentle-ai/                     # Gentle-AI estable, compilado por Nix
│   ├── engram/                        # Engram estable, compilado por Nix
│   ├── pi/                             # Pi + extensiones, lockfile npm fijado
│   ├── gentle-ai-bootstrap/           # inicialización idempotente de estado
│   └── cisco-packet-tracer/           # paquete con .deb propietario por hash
├── hosts/
│   └── loon-laptop/
│       ├── default.nix                # "main.rs" — identidad + hardware, solo compone
│       ├── power.nix                  # perfil AC/batería exclusivo del Dell
│       └── hardware-configuration.nix # autogenerado (NO tocar)
└── modules/                           # "src/core" — lógica reutilizable
    ├── default.nix                    # "mod.rs" raíz — importa todos los módulos
    ├── system/                        # boot, timezone, locale, systemPackages, wrappers
    ├── networking/                    # networkmanager, firewall
    ├── services/                      # compone sub-servicios
    │   ├── openssh/                   # daemon SSH endurecido
    │   └── tailscale/                 # red mesh privada (WireGuard)
    ├── programs/                      # shells y programas de usuario
    │   ├── fish/                      # shell + prompt oh-my-posh
    │   ├── ghostty/                   # terminal (config gestionada)
    │   ├── waybar/                    # barra de estado (config + estilo)
    │   ├── equibop/                   # Discord con fix de WebRTC (Tailscale)
    │   └── gentle-ai/                 # stack Gentle-AI/Pi/Engram + bootstrap
    ├── wayland/                       # compositores Wayland y greeter
    │   ├── niri/                      # compositor niri (config.kdl gestionado)
    │   └── dms-greeter/               # greeter DankMaterialShell
    └── users/                         # usuario loonbac, grupos, npm-global
```

---

## Filosofía: estructura modular

| Concepto                        | Esta config                          |
|---------------------------------|--------------------------------------|
| `flake.nix` (deps + outputs)    | "Cargo.toml" del sistema             |
| `hosts/loon-laptop/default.nix` | "main.rs" — solo compone             |
| `modules/default.nix`           | "mod.rs" raíz                        |
| `modules/services/default.nix`  | "mod" que compone sub-servicios      |
| `modules/services/openssh/`     | cada servicio es un módulo propio    |
| `pkgs/loon-launch/`             | binario propio del flake             |
| `imports = [ ./foo ];`          | el "mod foo;"                        |
| `rebuild`                       | el "cargo build && cargo run"        |

---

## Comando custom: `rebuild`

En lugar de escribir `sudo nixos-rebuild switch --flake .#loon-laptop` cada vez,
este flake incluye un comando propio **`rebuild`** que lo hace por ti.

```bash
rebuild          # aplica los cambios (switch) — el más usado
rebuild dry      # prueba sin aplicar (dry-run)
rebuild update   # actualiza nixpkgs y los flakes (flake update) y aplica
```

- Se ejecuta desde cualquier directorio: internamente entra a `~/.nixos`.
- Pide sudo solo cuando aplica (switch/update).
- El código vive en `pkgs/rebuild/default.nix`; la instalación se hace
  desde `modules/system/default.nix`.

> **Nota**: `rebuild update` también actualiza el `flake.lock`, lo que trae
> las últimas versiones de Zen Browser y VS Code Insiders (ver abajo).

---

## Comando custom: `nixos-ssh`

Toggle de autenticación del servidor OpenSSH. Pregunta si se quiere entrar
por contraseña o por clave (certificado) y aplica la config con el mismo
`nixos-rebuild switch` que `rebuild`.

```bash
nixos-ssh        # menú: password | cert | cancelar
```

- Muestra el modo actual antes de preguntar.
- Escribe el modo en `modules/services/openssh/ssh-auth-mode` y aplica.
- Si el rebuild falla, revierte el archivo de estado al modo anterior.
- El módulo cae a `cert` (seguro: solo claves) si el archivo falta o inválido.
- Código en `pkgs/nixos-ssh/default.nix`; instalado en `modules/system/default.nix`.

---

## Paquetes del flake (`pkgs/`)

### `loon-launch` — app launcher (Super+Space) y fondos (Super+B)

Launcher Wayland en Rust (GTK4 + libadwaita) para niri. Daemon persistente:
`Super+Space` abre las apps; `Super+B` (o `loon-launch wallpapers`) abre el
selector de fondos. El código vive en `pkgs/loon-launch/src/` (`ui/`,
`filter.rs`, `wallpapers.rs`).

**Apps (680×350)**

- Banner 180 px con la imagen estética y búsqueda de 600 px centrada encima.
- Lista en **2 columnas** de 4 filas: icono 28 px + nombre (ellipsis). Las
  columnas extra se desplazan a la derecha (scrollbar oculta; flechas).
- `←/→` cambian de columna, `↑/↓` suben/bajan en la columna, `Enter` ejecuta,
  `Escape` cierra. Escribir filtra; `>` son acciones de poder.

**Fondos (740×350, sin banner ni búsqueda)**

- Fila de arriba: **Fondo de pantalla** (videos de `~/Videos/Wallpapers`,
  preview en vivo 16:9). Si hay más de dos, `→` scrollea la tira.
- Fila de abajo: **Background** (fotos de `~/Pictures/Wallpaper`).
- Cards centradas, badge Video/Foto, borde interno al seleccionar. El scroll
  deja 22 px de aire para no recortar el aro al volver al primero.
- `↑/↓` saltan entre las dos filas. `Enter` aplica (`mpvpaper-wallpaper set`
  o `niri-backdrop set`).

Validar: `niri validate --config modules/wayland/niri/config.kdl` y
`cargo test` en `pkgs/loon-launch/`.

Se compila con `rustPlatform.buildRustPackage` (Cargo.lock versionado).
Código: `pkgs/loon-launch/src/main.rs`.

Para validar cambios del launcher:

```bash
nix build .#loon-launch --no-link --print-out-paths
nix-shell -p cargo rustc pkg-config gtk4 glib libadwaita glib-networking gobject-introspection --run 'cargo test'
```

### `niri-cycle` — mover ventanas con wrap (Super+←/→)

En niri las ventanas viven en columnas horizontales. Este script usa
`niri msg action focus-column-left/right` y si estás en el extremo, salta
al otro lado (wrap infinito).

### `mpvpaper-wallpaper` — fondo animado (Super+B)

Reproduce un video en loop detrás de las ventanas con `mpvpaper`:

```bash
mpvpaper-wallpaper              # reproduce el video seteado (o el primero)
mpvpaper-wallpaper set NOMBRE   # setea un video de ~/Videos/Wallpapers
mpvpaper-wallpaper list         # lista los videos disponibles
mpvpaper-wallpaper pause        # pausa por IPC y conserva el último frame
mpvpaper-wallpaper resume       # reanuda el mismo proceso/video
mpvpaper-wallpaper status       # playing, paused o stopped
mpvpaper-wallpaper stop         # detiene el fondo animado
```

Se lanza automáticamente al iniciar la sesión (`spawn-at-startup` en niri).
El socket IPC de mpv queda bajo `$XDG_RUNTIME_DIR/mpvpaper-wallpaper/`, con
permisos privados del usuario; no se usa `/tmp` compartido.

### `accent-wallpaper` — acento dinámico desde el wallpaper

Extrae el color más llamativo del video de wallpaper y lo aplica como color de
acento del sistema (borde de ventana activa en niri + underbar/botones de
loon-bar). Usa `ffmpeg` para tomar un frame y `imagemagick` para analizar el
histograma (el color más saturado × brillante, descartando casi negros):

```bash
accent-wallpaper             # analiza el video seteado
accent-wallpaper from VIDEO  # analiza un video específico
```

Escribe `~/.config/mpvpaper/accent.txt` (hex) y `~/.config/niri/accent.kdl`
(override del border de niri, que recarga en vivo al cambiar). Tanto
`mpvpaper-wallpaper` como `niri-backdrop` lo disparan automáticamente al
cambiar de fondo; loon-bar y Pi vigilan `accent.txt` y actualizan sus colores
sin reiniciar.

### `niri-backdrop` — fondo estático del backdrop

Pone una imagen fija (con `awww`) en la capa **backdrop** de niri — el fondo
global que se ve detrás de todo, incluido a través de las ventanas transparentes
con `xray`. También recalcula en segundo plano la paleta compartida a partir de
la imagen elegida. Imágenes en `~/Pictures/Wallpaper`:

```bash
niri-backdrop              # pone la imagen seteada (o la primera)
niri-backdrop set IMAGEN   # setea una imagen específica
niri-backdrop stop         # detiene el fondo
```

### Gentle-AI + Pi + Engram — instalación reproducible

El stack está declarado en `modules/programs/gentle-ai/` y sus paquetes están
en `pkgs/`. Gentle-AI está fijado en la versión estable `2.6.0`; Gentle-Pi usa
el snapshot reproducible de `main` `8103f0fa` con Gentle Agents y Gentle Todo.
Engram está fijado en `1.20.0` y Pi en `0.84.4`, con estas extensiones exactas:

- `gentle-pi` `main@8103f0fa`
- `gentle-engram` `0.1.10`
- `pi-mcp-adapter` `2.31.0`
- `pi-web-access` `0.27.0`
- `@juicesharp/rpiv-ask-user-question` `2.7.1`
- `pi-btw` `0.4.1`
- `pi-commandcode-provider` `0.6.0`

`gentle-ai-bootstrap` se ejecuta al iniciar la sesión y también puede
ejecutarse manualmente. Enlaza los paquetes desde `/nix/store`, conserva una
copia de cualquier instalación anterior en `~/.pi/agent/backups/`, configura
Engram en `~/.pi/agent/mcp.json` y activa RDD global en una instalación nueva.
Gentle Agents reemplaza los plugins anteriores de subagentes y ejecuta cada
agente como un hijo RPC aislado; Gentle Todo reemplaza `@juicesharp/rpiv-todo`.
El bootstrap retira esas extensiones de forma recuperable, pero conserva los
agentes, perfiles de modelos, sesiones y configuración del usuario.
También retira los binarios mutables antiguos de `~/go/bin`, `~/.local/bin` y
`~/.npm-global/bin` hacia ese backup para que no haya dos implementaciones en
`PATH`. No reemplaza credenciales, modelos, sesiones ni la base de datos de
Engram.

```bash
gentle-ai-bootstrap
gentle-ai version
engram version
pi --version
gentle-ai doctor
```

#### Defensa contra ataques a la cadena de suministro

Aunque el ecosistema Pi publica instrucciones con npm, npm solo se usa dentro
del build reproducible de Nix. `pkgs/pi/package-lock.json` contiene versiones,
URLs del registry e integridad SHA-512 para toda la clausura; `npmDepsHash`
fija además la caché que consume Nix. Nix obtiene esa caché una vez y verifica
su hash; después npm solo ejecuta `npm ci --offline` y
`npm rebuild --ignore-scripts`, sin resolver ni descargar nada y sin ejecutar
`postinstall` de terceros. En particular, se bloquea el instalador de
`gentle-pi` que intentaría descargar otro binario de Gentle-AI: Pi recibe el
mismo binario `gentle-ai` fijado en el store Nix mediante
`GENTLE_PI_GENTLE_AI_DEV_BINARY`.

Por eso no se debe ejecutar `npm install`, `npm update`, `pi update` ni
`gentle-ai upgrade` sobre esta instalación administrada. Para actualizar:

1. cambia intencionalmente la versión y los hashes en `pkgs/`;
2. regenera el lockfile únicamente desde un registry confiable y revisa el
   diff completo;
3. valida con `nix flake check` y `nix build .#pi .#gentle-ai .#engram`;
4. aplica con `rebuild`.

La autenticación, sesiones, contenido de `~/.engram/` y cualquier token quedan
fuera de Git y del store Nix.

### Cisco Packet Tracer

Packet Tracer vuelve a formar parte del perfil del sistema usando el instalador
propietario que ya tienes. El `.deb` no se guarda en Git: su hash SHA-256 está
fijado en `pkgs/cisco-packet-tracer/default.nix`. Para repetirlo en otra
máquina hay que obtener legalmente el mismo instalador y añadirlo al store:

```bash
nix store add --mode flat --hash-algo sha256 \
  --name CiscoPacketTracer900_Open_Beta_July_Build680_linux_amd64_Exp20251231.deb \
  /ruta/al/CiscoPacketTracer900_Open_Beta_July_Build680_linux_amd64_Exp20251231.deb
rebuild
packettracer9
```

El archivo actual es una beta `9.0.0` con vencimiento declarado `2025-12-31`.
Si Cisco te entrega una versión nueva, cambia el nombre y el hash del paquete
Nix de forma intencional antes del rebuild.

---

## Entorno gráfico: niri + greeter

### niri (`modules/wayland/niri/`)

Compositor Wayland **scrollable-tiling**. La config `config.kdl` se gestiona
desde NixOS: se instala en `/etc/niri/config.kdl` y `~/.config/niri/config.kdl`
es un symlink (tmpfiles). **No edites `~/.config/niri` a mano**; edita el repo
y corre `rebuild`.

Detalles de la config:

- **Layout**: ventanas al 100% del ancho, gaps de 16px, esquinas redondeadas
  (12px), borde fino de 1px (sin fondo sólido para no tapar transparencias),
  sin focus-ring.
- **Fondo transparente**: `background-color "transparent"` deja ver el backdrop
  (donde está el wallpaper).
- **Teclado**: layout `es`, numlock activo. Touchpad con tap y clickfinger.
- **Portapapeles persistente**: `wl-clip-persist` corre al inicio de la sesión
  (con `wl-clipboard` + `cliphist`) para que el contenido copiado no se pierda
  al cerrar la app dueña — imprescindible para pegar capturas de la UI de niri
  en otros programas tras cerrarla.
- **Historial de portapapeles**: `cliphist` guarda texto e imágenes copiadas
  (con watchers de `wl-paste`) y `Super+Shift+V` permite recuperarlas con el
  picker `fuzzel` — workaround para el bug de Chromium/Electron (p. ej.
  Equibop/Discord) que no pega imágenes que no provienen de un navegador.
- **Acento dinámico**: el borde de la ventana activa usa el color extraído del
  wallpaper por `accent-wallpaper` (include `~/.config/niri/accent.kdl`).
- **Modo oscuro global**: `programs.dconf` con `color-scheme = prefer-dark` +
  `gtk-theme = Adwaita-dark`, y `GTK_THEME=Adwaita-dark` en sessionVariables
  para apps Electron.
- **Window-rule de ghostty**: transparencia real a nivel de compositor
  (`opacity 0.8` + `background-effect xray true` para ver el wallpaper a través).

#### Atajos de teclado (binds)

| Tecla               | Acción                                          |
|---------------------|-------------------------------------------------|
| `Super+Return`      | Abrir ghostty                                   |
| `Super+E`           | Abrir Nautilus (explorador de archivos)         |
| `Super+Space`       | Abrir loon-launch (launcher)                    |
| `Super+Q`           | Cerrar ventana                                  |
| `Super+F`           | Maximizar/restaurar columna                     |
| `Super+B`           | Selector de fondos en loon-launch               |
| `Super+Shift+S`     | Captura de pantalla (área) → portapapeles       |
| `Super+Shift+V`     | Pegar desde historial (cliphist + fuzzel)       |
| `Super+←` / `→`     | Mover ventana con wrap (niri-cycle)             |
| `Super+1..9`        | Cambiar de workspace                            |
| `Fn+F6` / `Fn+F7`   | Bajar/subir brillo (`brightnessctl` ±10%)       |
| `Fn+F2` / `Fn+F3`   | Bajar/subir volumen (`wpctl` ±5%)               |

### dms-greeter (`modules/wayland/dms-greeter/`)

Greeter **DankMaterialShell** sobre el compositor niri. Config fina del tema en
`~/.config/DankMaterialShell/settings.json`.

---

## Servicios (`modules/services/`)

### OpenSSH (`openssh/`)

Daemon SSH **endurecido**: solo acceso por clave (`PasswordAuthentication = false`),
root no puede entrar (`PermitRootLogin = "no"`).

### Tailscale (`tailscale/`)

Red mesh privada (WireGuard) para conectar dispositivos entre sí.

```bash
sudo tailscale up   # autenticar y unir la máquina a la tailnet (una vez)
tailscale status    # ver el estado y los dispositivos
```

---

## Programas (`modules/programs/`)

### fish (`fish/`)

Shell por defecto del usuario:

- Sin banner de bienvenida.
- **Detección automática de binarios**: agrega al PATH los directorios que
  existan (`~/.npm-global/bin`, `~/.cargo/bin`, `~/.local/bin`, pipx, etc.)
  — cualquier paquete instalado globalmente funciona sin configurar nada.
- **Prompt Oh My Posh** con el tema *craver*, gestionado por NixOS
  (se instala en `/etc/oh-my-posh/craver.omp.json`, versionado en el repo).

### ghostty (`ghostty/`)

Terminal con config gestionada por NixOS (mismo patrón que niri: se instala en
`/etc/ghostty/config` y `~/.config/ghostty/config` es symlink):

- Sin barra de título (`window-decoration = false`).
- Padding interno de 12px.
- Fondo opaco por defecto; la transparencia real la aplica niri (window-rule).
- Atajos: `ctrl+shift+t` nueva pestaña, `ctrl+shift+w` cerrar pestaña,
  `ctrl+shift+,` recargar config en caliente.

### nautilus (`nautilus/`)

Explorador de archivos GNOME. En NixOS 26.05 la opción `programs.nautilus` fue
removida, así que el módulo instala `nautilus` + `gvfs` (montajes, trash,
samba) en `systemPackages` y habilita `programs.dconf` para los settings GTK.

### waybar (`waybar/`)

Barra de estado inferior (Waybar v0.15), config gestionada por NixOS
(mismo patrón: `/etc/waybar/` + symlinks en `~/.config/waybar/`). Se lanza
automáticamente al iniciar la sesión (`spawn-at-startup "waybar"` en niri).

- **Módulos**: workspaces y ventana de niri, reloj, volumen (pulseaudio),
  red, brillo, batería y bandeja del sistema.
- **Estilo**: tema Nord consistente con niri (colores `#3b4252`, `#5e81ac`, ...).
- **Editar**: `modules/programs/waybar/config.jsonc` (módulos) y
  `modules/programs/waybar/style.css` (estilos) → `rebuild`.
- **Recargar la barra** sin reiniciar sesión: `killall waybar && waybar &`.

### equibop (`equibop/`)

Cliente Discord **Equibop** con un fix de WebRTC para que el voice chat
funcione con Tailscale (o cualquier VPN) activo. El autostart está gestionado
por NixOS (mismo patrón: `/etc/equibop/` + symlink en `~/.config/autostart/`).

**El problema**: con una VPN activa, WebRTC se confunde y se bindea a la
interfaz de la VPN, quedando la llamada colgada en *"DTLS Connecting"*.

**El fix**: se parchea el `app.asar` del paquete en cada build — se inyecta en
`dist/js/main.js` un hook `app.on("web-contents-created", ...)` que llama
`setWebRTCIPHandlingPolicy("default_public_and_private_interfaces")` en cada
ventana (el mismo fix de [Vesktop PR #1283](https://github.com/Vencord/Vesktop/pull/1283)).

> **OJO (gotchas)**: la bandera de Chromium `--webrtc-ip-handling-policy` NO
> sirve (Equibop no la lee). El valor `disable_non_proxied_udp` NO sirve
> (desactiva el UDP directo y deja la llamada en *"RTC Connecting"*). El único
> valor que funciona con VPNs es `default_public_and_private_interfaces`.

---

## Sistema (`modules/system/`)

- **Boot**: systemd-boot + UEFI.
- **Zona horaria / locale**: `America/Lima`, `es_PE.UTF-8`, teclado `es`.
- **Paquetes no libres**: `allowUnfree = true` (microcode Intel, etc.).
- **Brillo**: wrapper setuid de `brightnessctl` (`security.wrappers`) para que
  las teclas Fn+F6/F7 funcionen sin contraseña.
- **Paquetes globales** (`environment.systemPackages`): git, gh, btop,
  fastfetch, ghostty, nodejs, brightnessctl, zen-browser, vscode-insiders,
  equibop, fish, yazi, mpvpaper/mpv, oh-my-posh, los scripts propios
  (niri-cycle, loon-launch, rebuild, mpvpaper-wallpaper, niri-backdrop),
  Gentle-AI, Engram, Pi, Packet Tracer y `gentle-ai-bootstrap`, además de
  utilidades de diagnóstico (libva-utils, pciutils, usbutils, dmidecode, inxi,
  lshw, iw).
- **Keyring** (`services.gnome.gnome-keyring.enable`): requisito de Settings
  Sync de VS Code (Secret Service `org.freedesktop.secrets`). Niri no lo
  levanta solo, por eso se declara explícitamente.

## Red (`modules/networking/`)

- **NetworkManager** activo (WiFi, ethernet por GUI).
- **Firewall** activo por defecto; para abrir puertos:
  `networking.firewall.allowedTCPPorts = [ ... ]` /
  `networking.firewall.allowedUDPPorts = [ ... ]`.

## Usuarios (`modules/users/`)

- Usuario `loonbac` (Joshua Rosales), grupos: `networkmanager` (red) y
  `wheel` (sudo). Shell: fish.
- **npm global**: `~/.npm-global` creado y agregado al PATH (el prefix del
  store de Nix es inmutable).

---

## Flake (`flake.nix`)

**Inputs**:

| Input                 | Qué aporta                                        |
|-----------------------|---------------------------------------------------|
| `nixpkgs`             | `nixos-26.05`                                     |
| `zen-browser`         | Zen Browser (no está en nixpkgs)                  |
| `code-insiders-flake` | VS Code Insiders (auto-update diario)             |

**Paquetes expuestos** (`packages.x86_64-linux`): `rebuild`, `loon-launch`,
`niri-cycle`, `vscode-insiders`, `zen-browser`, `gentle-ai`, `engram`, `pi` y
`gentle-ai-bootstrap`, `cisco-packet-tracer`.

**VS Code Insiders**: el flake upstream solo aporta su `meta.json` (versión +
sha256 + URL del tarball, actualizado a diario por su CI). Lo leemos con
`builtins.readFile` y construimos el paquete con `pkgs.vscode.override
{ isInsiders = true; }`, anulando las fases de nixpkgs que asumen una
estructura que Insiders no trae (`patchPhase` de ripgrep y `postFixup` de
vsce-sign). Así `rebuild update` siempre instala la última versión.

---

## Comandos útiles (sin el custom)

```bash
# Aplicar cambios (desde ~/.nixos)
sudo nixos-rebuild switch --flake .#loon-laptop

# Probar sin aplicar (dry-run)
sudo nixos-rebuild dry-run --flake .#loon-laptop

# Ver qué se exporta el flake
nix flake show
nix flake check

# Actualizar nixpkgs y los flakes (el "cargo update" de NixOS)
nix flake update

# Probar un paquete custom sin instalarlo
nix run .#rebuild
nix run .#loon-launch
```

---

## Cómo agregar un paquete al sistema

1. Busca el nombre: `nix search nixos <paquete>`
2. Edita `modules/system/default.nix`:

```nix
environment.systemPackages = with pkgs; [
  htop
  neovim
];
```

3. Aplica: `rebuild` (o `sudo nixos-rebuild switch --flake .#loon-laptop`)

## Cómo agregar un servicio (ej. Docker)

1. Crea la carpeta `modules/services/docker/default.nix`:

```nix
{ config, lib, pkgs, ... }:
{
  virtualisation.docker.enable = true;
}
```

2. Registra el módulo en `modules/services/default.nix`:

```nix
imports = [
  ./openssh
  ./tailscale
  ./docker
];
```

3. Aplica: `rebuild`

## Cómo agregar un compositor Wayland (ej. Hyprland)

1. Crea la carpeta `modules/wayland/hyprland/default.nix`:

```nix
{ config, lib, pkgs, ... }:
{
  programs.hyprland.enable = true;
}
```

2. Registra el módulo en `modules/wayland/default.nix`:

```nix
imports = [
  ./niri
  ./hyprland
];
```

3. Aplica: `rebuild`

## Cómo agregar una máquina nueva (ej. "desktop")

1. Crea `hosts/desktop/default.nix` con su `hardware-configuration.nix`.
2. Declárala en `flake.nix`:

```nix
nixosConfigurations = {
  "loon-laptop" = mkHost "loon-laptop" [ ];
  desktop       = mkHost "desktop" [ ];
};
```

3. Aplica desde esa máquina: `sudo nixos-rebuild switch --flake .#desktop`

---

## Notas sobre el host (`hosts/loon-laptop/`)

- Hostname: `loon-laptop` — Dell Inspiron 15 3520.
- **GPU Intel Iris Xe** (Alder Lake, i915): stack gráfico + VA-API con
  `intel-media-driver` (iHD) y runtime oneVPL (`vpl-gpu-rt`) para encode por
  hardware en OBS (QSV). `LIBVA_DRIVER_NAME=iHD` en las sessionVariables.
- **Firmware redistribuible**: WiFi Realtek 8821CE, Bluetooth Realtek y
  microcode Intel — sin esto el WiFi no funciona.
- **Bluetooth Realtek**: servicio habilitado (`hardware.bluetooth.enable`)
  con `powerOnBoot` para que el adaptador arranque con la sesión.
- **Perfil AC/batería aislado**: `power.nix` es importado únicamente por
  `hosts/loon-laptop/default.nix`. En batería selecciona 60,206 Hz, pausa
  mpvpaper por IPC, usa EPP `power`, turbo desactivado, gobernador
  `powersave`, ahorro Wi-Fi, runtime PM seguro, ALPM SATA y reposo del HDD a
  los 15 minutos; también usa `snd_hda_intel power_save=1`, desactiva el NMI
  watchdog y alarga el writeback a 15 segundos. En AC restaura 120,213 Hz y
  el comportamiento normal.
- **Eventos del cargador**: un timer systemd aplica un debounce de 30 segundos
  a las ráfagas ACPI online/offline del adaptador Dell, para que el perfil no
  quede interrumpido, parcialmente aplicado ni bloqueado por el límite de
  arranques de systemd. Los eventos duplicados tampoco repiten el atomic commit
  de niri ni reprograman `hdparm`.
- **HDD Toshiba**: el valor `hdparm -S 180` equivale a 15 minutos. Se eligió
  deliberadamente para permitir reposo sin causar ciclos frecuentes de
  parada/arranque; el disco nunca se desmonta ni se fuerza a dormir.
- **Bluetooth en batería**: solo se bloquea si `bluetoothctl` confirma que no
  hay dispositivos conectados. Al volver a AC se desbloquea y enciende.
- **USB**: el receptor KYE `0458:019d` queda exceptuado de autosuspend para
  evitar lag. No existe una política USB global.
- Estado: `26.05`.

## Notas de seguridad

- `PasswordAuthentication = false` → solo se puede entrar por **clave SSH**.
- `PermitRootLogin = "no"` → root no entra por SSH.
- El firewall está **activo** por defecto; para abrir puertos, ver
  `modules/networking/default.nix`.
- La contraseña de `loonbac` NO se guarda en este repo: se define con
  `passwd` en la máquina.
- Cisco Packet Tracer se incluye mediante `pkgs/cisco-packet-tracer`, pero su
  `.deb` propietario debe aportarse manualmente y coincidir con el hash fijado;
  nunca se descarga automáticamente ni se versiona dentro de Git.

## ¿Por qué no hay `configuration.nix` ya?

Porque fue **reemplazado** por la estructura de flake. El archivo `/etc/nixos/configuration.nix`
ahora es un enlace simbólico hacia `~/.nixos/hosts/loon-laptop/default.nix` para que
`nixos-generate-config` y herramientas antiguas sigan funcionando; pero el flake
es la fuente de verdad. La configuración vieja quedó respaldada en
`~/.nixos/configuration.nix.bak` (no se versiona, está en `.gitignore`).
