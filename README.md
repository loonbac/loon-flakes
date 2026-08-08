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
│   └── niri-backdrop/                 # fondo estático del backdrop
├── hosts/
│   └── loon-laptop/
│       ├── default.nix                # "main.rs" — identidad + hardware, solo compone
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
    │   └── equibop/                   # Discord con fix de WebRTC (Tailscale)
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

## Paquetes del flake (`pkgs/`)

### `loon-launch` — app launcher (Super+Space)

Launcher Wayland en Rust (GTK4 + libadwaita) para niri. La ventana es fija y
compacta: **680×350 px** de contenido. El banner ocupa 180 px de alto y el
listado de apps usa los 170 px restantes.

- Lista las apps desde los `.desktop` de `/run/current-system/sw/share/applications`,
  `~/.local/share/applications` y `/usr/share/applications`.
- Cada celda muestra un **icono de 44 px** arriba y el nombre centrado debajo,
  con elipsis para nombres largos; el grid está compactado para mostrar al menos
  dos filas completas dentro de la ventana.
- El banner usa una imagen natural de 1280×427 dibujada en un viewport fijo de
  680×180: se centra y se recortan los bordes horizontales superior e inferior,
  sin escalar la imagen para adaptarla al contenedor.
- La búsqueda mide 600 px, conserva su grosor normal y se dibuja superpuesta al
  banner. No recibe el foco inicial: el grid recibe el foco para que las flechas
  naveguen las apps.
- Navegación 100% por teclado: `←/→/↑/↓` mueven la selección, `Enter` ejecuta,
  `Escape` cierra, las teclas imprimibles filtran y `Backspace` borra.
- **Modo poder**: escribiendo `>` se filtran acciones de sistema
  (apagar, reiniciar, hibernar, suspender, bloquear).
- El launcher se cierra al perder el foco de la ventana.

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
mpvpaper-wallpaper stop         # detiene el fondo animado
```

Se lanza automáticamente al iniciar la sesión (`spawn-at-startup` en niri).

### `niri-backdrop` — fondo estático del backdrop

Pone una imagen fija (con `swaybg`) en la capa **backdrop** de niri — el fondo
global que se ve detrás de todo, incluido a través de las ventanas transparentes
con `xray`. Imágenes en `~/Pictures/Wallpaper`:

```bash
niri-backdrop              # pone la imagen seteada (o la primera)
niri-backdrop set IMAGEN   # setea una imagen específica
niri-backdrop stop         # detiene el fondo
```

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
- **Window-rule de ghostty**: transparencia real a nivel de compositor
  (`opacity 0.8` + `background-effect xray true` para ver el wallpaper a través).

#### Atajos de teclado (binds)

| Tecla               | Acción                                          |
|---------------------|-------------------------------------------------|
| `Super+Return`      | Abrir ghostty                                   |
| `Super+Space`       | Abrir loon-launch (launcher)                    |
| `Super+Q`           | Cerrar ventana                                  |
| `Super+F`           | Maximizar/restaurar columna                     |
| `Super+B`           | Fondo animado (mpvpaper-wallpaper)              |
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
  y utilidades de diagnóstico (libva-utils, pciutils, usbutils, dmidecode,
  inxi, lshw, iw).

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
`niri-cycle`, `vscode-insiders`, `zen-browser`.

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
- **GPU Intel Iris Xe**: stack gráfico + VA-API con `intel-media-driver` (iHD)
  para aceleración por hardware.
- **Firmware redistribuible**: WiFi Realtek 8821CE, Bluetooth Realtek y
  microcode Intel — sin esto el WiFi no funciona.
- Estado: `26.05`.

## Notas de seguridad

- `PasswordAuthentication = false` → solo se puede entrar por **clave SSH**.
- `PermitRootLogin = "no"` → root no entra por SSH.
- El firewall está **activo** por defecto; para abrir puertos, ver
  `modules/networking/default.nix`.
- La contraseña de `loonbac` NO se guarda en este repo: se define con
  `passwd` en la máquina.

## ¿Por qué no hay `configuration.nix` ya?

Porque fue **reemplazado** por la estructura de flake. El archivo `/etc/nixos/configuration.nix`
ahora es un enlace simbólico hacia `~/.nixos/hosts/loon-laptop/default.nix` para que
`nixos-generate-config` y herramientas antiguas sigan funcionando; pero el flake
es la fuente de verdad. La configuración vieja quedó respaldada en
`~/.nixos/configuration.nix.bak` (no se versiona, está en `.gitignore`).
