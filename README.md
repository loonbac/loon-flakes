# loon-flakes — Configuración modular multi-host de NixOS

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
│   ├── gentle-ai-launcher/            # resuelve el runtime verificado de gentle-pi
│   ├── engram-launcher/               # launcher de Engram mutable
│   ├── engram-updater/                # descarga releases y verifica SHA-256
│   ├── pi-launcher/                    # bootstrap/launcher de Pi mutable
│   ├── pi/                             # assets locales de Pi (skills + UI custom)
│   ├── gentle-ai-bootstrap/           # inicialización idempotente de estado
│   ├── gentle-stack-update/            # actualiza Pi + extensiones + Gentle AI + Engram
│   ├── citron-nextendo/                # AppImage fijado del fork Citron Nextendo
│   └── cisco-packet-tracer/           # paquete con .deb propietario por hash
├── hosts/
│   ├── loon-laptop/
│   │   ├── default.nix                # "main.rs" — identidad, solo compone
│   │   ├── platform.nix               # plataforma exclusiva del Dell
│   │   ├── power.nix                  # perfil AC/batería exclusivo del Dell
│   │   └── hardware-configuration.nix # autogenerado (NO tocar)
│   └── nixos-pc/
│       ├── default.nix                # identidad, solo compone
│       ├── platform.nix               # plataforma AMD/NVIDIA del PC
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
    │   ├── citron-nextendo/           # módulo opcional del emulador
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

En lugar de escribir `sudo nixos-rebuild switch --flake .#<hostname>` cada vez,
este flake incluye un comando propio **`rebuild`** que lo hace por ti.

```bash
rebuild          # aplica los cambios (switch) — el más usado
rebuild dry      # prueba sin aplicar (dry-run)
rebuild update   # actualiza nixpkgs y los flakes (flake update) y aplica
```

- Se ejecuta desde cualquier directorio: internamente entra a `~/.nixos`.
- Detecta el hostname actual y selecciona su `nixosConfiguration`; falla de
  forma segura si el host no está declarado en el flake.
- Pide sudo solo cuando aplica (switch/update).
- El código vive en `pkgs/rebuild/default.nix`; la instalación se hace
  desde `modules/system/default.nix`.

La generación del sistema ejecuta además `niri validate` contra un HOME limpio.
Los directorios y archivos incluidos por Niri se crean declarativamente con
tmpfiles, de modo que una instalación nueva no depende de estado previo del usuario.
El launcher tampoco requiere archivos privados del home: si la imagen opcional
del banner no está disponible, utiliza un degradado integrado.
Waybar, loon-launch y los daemons persistentes de Niri son servicios de usuario
supervisados: se inician y detienen con la sesión y se recuperan de un fallo.

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

Al cambiar de video, mantiene el wallpaper anterior y hace un crossfade de
0.8 segundos sobre él; el proceso viejo se cierra solo cuando el nuevo ya es
completamente opaco.

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
sin reiniciar. Waybar observa su `colors.css` importado y actualiza la paleta
dentro del mismo proceso, sin desaparecer durante la transición.

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

### Gentle-AI + Pi + Engram — configuración declarativa, runtime actualizable

El módulo `modules/programs/gentle-ai/` separa configuración y runtime:

- NixOS declara los launchers, los modelos predeterminados, las rutas de los
  agentes, GGA, MCP y las preferencias portables.
- Pi vive en `~/.local/share/loon-pi/npm-prefix` como una instalación npm
  global normal y escribible, pero fuera de `PATH`; el launcher de Nix es la
  única entrada visible.
- Las extensiones viven en `~/.pi/agent/npm`; sus fuentes npm no llevan una
  versión fija, de modo que `pi update --extensions` puede actualizarlas.
- `gentle-pi` instala dentro de su propio paquete el binario exacto y verificado
  de Gentle AI con el que es compatible. El launcher `gentle-ai` siempre
  resuelve ese binario; no existe una segunda copia fijada por Nix.
- Engram vive en `~/.local/share/loon-engram`; `engram update` instala la última
  release oficial después de verificar su checksum publicado.

`gentle-ai-bootstrap` se ejecuta al iniciar sesión y también puede ejecutarse
manualmente. En una máquina nueva instala únicamente lo que falta; nunca
actualiza silenciosamente una instalación existente. Durante la migración
retira de forma recuperable los antiguos enlaces a `loon-gentle-pi-stack` y
los conserva bajo `~/.pi/agent/backups/`.

El bootstrap mantiene declarativos el tema, el proveedor/modelo principal,
las rutas de modelos para subagentes y el proveedor local `ollama-vast`. No
reemplaza credenciales, modelos descubiertos, sesiones ni la base de datos de
Engram. `better-claude-code-ui` es la única extensión deliberadamente fijada:
usa la variante local versionada en este repositorio.

```bash
gentle-ai-bootstrap
gentle-ai version
engram version
pi --version
gentle-ai doctor
```

#### Actualizaciones

Pi se puede actualizar directamente porque su ejecutable real ya no está en
`/nix/store`:

```bash
pi update                 # solo Pi
pi update --extensions    # gentle-pi y las demás extensiones
engram update             # solo Engram
gentle-stack-update       # Pi + extensiones + Gentle AI + Engram + configuración
```

Las esperas de Pi también están integradas con el escritorio: cualquier
`select`, `confirm`, `input`, editor o UI custom que un plugin abra mientras el
agente trabaja genera una notificación en SwayNC y reproduce un sonido por
PipeWire. Al terminar por completo una petición (`agent_settled`) se muestra y
suena otra alerta. La extensión que hace de puente se instala declarativamente
en `~/.pi/agent/extensions/loon-notifications.ts`; no depende del BEL de la
terminal ni se pierde al actualizar los paquetes npm. Ambos avisos usan el WAV
versionado en `pkgs/pi/assets/snd_shineselect.wav`, que Nix copia a su store.
Los procesos Pi internos de Gentle Agents y sus vueltas automáticas de entrega
están excluidos: completar un subagente no genera alertas; una pregunta que este
remita a la UI principal sí. Las preguntas usan `dialog-question`, los permisos
`dialog-warning` y solo el final de una petición principal usa
`dialog-information`. Los menús de plugins abiertos a mano se ignoran. Ghostty
ignora el BEL auxiliar de `rpiv-ask-user-question` para que no suene un segundo
aviso.

El bootstrap genera `pi-antigravity-alt` desde la versión instalada del paquete
oficial `pi-antigravity`, cambiando solo los identificadores necesarios para que
Pi lo trate como otra instancia. Sus modelos aparecen como
`antigravity-alt/<modelo>`, su OAuth se guarda por separado y sus comandos usan
el prefijo `/antigravity-alt.*`. Para iniciar o reparar la cuenta B:

```text
/login antigravity-alt
/antigravity-alt.usage
/antigravity-alt.models
```

`gentle-stack-update` actualiza primero el paquete oficial y luego regenera el
clon desde esa misma versión. El parche valida la estructura esperada antes de
reemplazarlo; si una actualización upstream resulta incompatible, conserva el
clon anterior y muestra una advertencia.

La extensión global `loon-antigravity-quota-fallback.ts` detecta errores de
agotamiento de cuota de ambas cuentas y mantiene un cooldown separado para
cada una. Usa el plazo de reinicio incluido en el error y cambia la petición y
las de los subagentes en este orden: Antigravity cuenta A → Antigravity cuenta
B con el mismo modelo y thinking → los dos fallbacks externos de la tabla. Al
terminar restaura el modelo original.

Los subagentes con Gemini 3.8 usan dos fallbacks específicos; no se configura
un tercero:

| Subagente | Fallback 1 | Fallback 2 |
| --- | --- | --- |
| `gentle-ai-explore` | DeepSeek V4.1 Flash `high` | Muse Spark 1.3 `xhigh` |
| `gentle-ai-worker` | Muse Spark 1.3 `max` | DeepSeek V4.1 Flash `high` |
| `jd-fix-agent` | DeepSeek V4.1 Flash `high` | Muse Spark 1.3 `max` |
| `sdd-explore` | DeepSeek V4.1 Flash `high` | Muse Spark 1.3 `xhigh` |
| `sdd-spec` | Muse Spark 1.3 `xhigh` | DeepSeek V4.1 Flash `high` |
| `sdd-tasks` | DeepSeek V4.1 Flash `high` | Muse Spark 1.3 `xhigh` |
| `sdd-apply` | Muse Spark 1.3 `max` | DeepSeek V4.1 Flash `high` |
| `sdd-onboard` | DeepSeek V4.1 Flash `high` | Muse Spark 1.3 `xhigh` |

`max` se conserva como la política solicitada. El catálogo actual de
`opencode-go/muse-spark-1.3-contributor` (free tier) declara `max: null`, por lo
que Pi lo ajusta a `xhigh`, su máximo efectivo; la extensión no sustituye ese
modelo por la variante de pago.

Al vencer el plazo, Pi vuelve a probar Antigravity automáticamente. El estado se
puede consultar con `/antigravity-fallback` o limpiar antes de tiempo con
`/antigravity-fallback clear`. Muse Contributor puede usar prompts y respuestas
para entrenamiento, según la política de OpenCode Go.

Actualizar `gentle-pi` ejecuta su instalador oficial y descarga el Gentle AI
correspondiente con verificación de integridad. npm autoriza únicamente el
script de instalación de `gentle-pi`, no los scripts de todas las dependencias.
`gentle-stack-update` vuelve a aplicar después los perfiles de modelos del
flake. No hay que editar versiones ni hashes Nix para actualizaciones normales
del stack.

Este diseño intercambia reproducibilidad binaria entre hosts por la capacidad
de autoactualización solicitada: el repositorio sigue declarando qué se instala
y cómo se configura, mientras que cada host decide cuándo avanzar sus versiones.
Las actualizaciones permanecen manuales y explícitas; el login solo repara
componentes ausentes.

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

### Veadotube Mini

Veadotube Mini 2.2 está empaquetado como binario externo para `nixos-pc`.
Su ZIP de itch.io usa enlaces temporales y no se guarda en Git; el paquete
fija el nombre y SHA-256 del release en `pkgs/veadotube-mini/default.nix`.
Antes del primer rebuild, añade el ZIP exacto al store:

```bash
nix store add --mode flat --hash-algo sha256 \
  --name veadotube-mini-linux-x64.zip \
  /ruta/a/veadotube-mini-linux-x64.zip
rebuild
```

El wrapper FHS conserva el layout `lib/` distribuido por upstream y aporta las
bibliotecas de sistema necesarias en NixOS. La app queda instalada en el perfil
del sistema con su entrada de escritorio, por lo que después del rebuild se
puede eliminar el ZIP original sin afectar la instalación. Se activa solo en
`hosts/nixos-pc/streaming.nix` mediante `programs.veadotube-mini.enable`.

### OBS PipeWire Video Source

`obs-pwvideo` añade a OBS una fuente genérica de vídeo PipeWire, útil para
recibir una salida de herramientas como libfunnel sin usar el portal de captura.
Se compila desde el último commit archivado de upstream, fijado por hash en
`pkgs/obs-pwvideo/default.nix`, y se instala mediante el wrapper oficial de
OBS; no copia plugins a `~/.config/obs-studio`. Está habilitado únicamente en
`nixos-pc` desde `hosts/nixos-pc/streaming.nix`.

Ese mismo archivo añade únicamente en `nixos-pc` un argumento al wrapper de
OBS para anteponer `/run/opengl-driver/lib` a `LD_LIBRARY_PATH`. El proceso
auxiliar `obs-nvenc-test` puede así cargar `libnvidia-encode.so.1` del driver
NVIDIA activo y ofrecer los codificadores NVENC de la RTX 3060. Los demás
hosts conservan el wrapper genérico y no heredan rutas ni supuestos de NVIDIA.

El PC también incluye `obs-pipewire-audio-capture`, que añade fuentes PipeWire
para capturar por separado una aplicación, una entrada o una salida de audio.
Se declara sólo en `hosts/nixos-pc/streaming.nix`; no afecta los demás hosts.

Para juegos y aplicaciones Vulkan/OpenGL, el estándar del PC es
`obs-vkcapture`: se crea una fuente **Captura de juego** y el programa se inicia
con `obs-gamecapture programa` o con un wrapper que defina `OBS_VKCAPTURE=1`.
La fuente espera silenciosamente al ejecutable y no usa el portal. Citron ya
incluye ese wrapper, por lo que **Citron-Video** se conecta automáticamente al
abrir el emulador.

Las capturas de ventanas genéricas bajo Wayland siguen dependiendo del portal.
Su `RestoreToken` sólo puede restaurarse si el contenido continúa disponible;
si la ventana desapareció, el protocolo abre nuevamente el selector. No se
debe usar una fuente PipeWire para un juego compatible con `obs-vkcapture`.

### Twitch GLaDOS TTS para OBS

`pkgs/obs-twitch-glados-tts/` instala un script Python nativo de OBS que escucha
el comando `!t` en `#loonbac21` mediante el IRC anónimo de Twitch y sintetiza
localmente con Sherpa-ONNX y el modelo español GLaDOS FP32. No usa OAuth, bot ni
daemon: la conexión, los hilos de trabajo y la cola solo existen dentro de OBS.
Los WAV se crean bajo `$XDG_RUNTIME_DIR/obs-twitch-glados-tts/` y se borran al
terminar de reproducirse o al descargar el script.

El wrapper declarado en `hosts/nixos-pc/streaming.nix` registra el script antes
de abrir OBS. Este crea la fuente `Twitch GLaDOS TTS`, visible en el mezclador
con fader propio. Canal, comando, límite, cooldown, volumen, monitorización y
velocidad se ajustan en **Herramientas → Scripts** y se recargan en vivo.

### Restauración limpia del streaming en `nixos-pc`

El flake reconstruye OBS y sus plugins (`obs-pwvideo`, Audio Monitor, captura
de audio PipeWire y captura de juego Vulkan), NVENC, Veadotube Mini, Pear
Desktop con `pear_twitch`, el TTS con su modelo GLaDOS, los overlays locales y
los parches de Equibop. No se deben copiar plugins manualmente a `~/.config` ni
`~/.local/share`.

El estado personal no se publica en Git. Para recuperar la misma disposición y
cuentas después de formatear, conservar de forma privada:

- `~/.config/obs-studio/basic/`: colecciones de escenas, perfiles, encoder y
  servicio de streaming.
- `~/.config/obs-studio/global.ini`, `user.ini` y, si se personaliza su panel,
  `plugin_config/audio-monitor/config.json`.
- `~/OBS/Escenas/`: HTML, imágenes y demás archivos locales usados por las
  fuentes de la colección.
- `~/.veadotube/data/mini/autosave.veado`: personaje actual de Veadotube.
- El ZIP original `veadotube-mini-linux-x64.zip` 2.2 con hash
  `sha256-JHgC9nhMTr76zavmj8kzmdTyOwWFdSJ1lEpx26yAnrA=`. Itch.io usa enlaces
  temporales y Nix no puede descargar legalmente ese archivo por sí solo.

Las sesiones de Equibop y Pear pueden iniciarse nuevamente; si se desea evitar
el login, sus directorios privados son `~/.config/equibop` y
`~/.config/YouTube Music`. Los WAV del TTS y el estado del overlay viven en
`XDG_RUNTIME_DIR`, son efímeros y nunca deben respaldarse.

### Citron Nextendo

El paquete `citron-nextendo` fija por hash la nightly oficial del fork Citron
Neo de Nextendo Network. Se distribuye para `x86_64-linux` y `aarch64-linux`,
instala su entrada de escritorio y las reglas udev para mandos Nintendo. El PC
usa `citron-nextendo-v3`, optimizado para CPUs x86-64-v3 como su Ryzen 7 5700X;
el módulo reutilizable usa por defecto la build x86_64 genérica. En este
repositorio está habilitado solamente desde `hosts/nixos-pc/gaming.nix`.

El workflow `.github/workflows/update-citron-nextendo.yml` consulta cada seis
horas la release oficial `nightly-linux`. Cuando cambia, verifica los SHA-256
publicados por GitHub, refleja los tres AppImages sin modificarlos en una
release inmutable `citron-nextendo-<commit>` y actualiza automáticamente
`pkgs/citron-nextendo/sources.json`. Así ningún host compila Citron y una
nightly antigua continúa disponible aunque upstream reemplace su release.

Otro flake NixOS puede reutilizar el módulo directamente:

```nix
{
  inputs.loon-flakes.url = "github:loonbac/loon-flakes";

  outputs = { nixpkgs, loon-flakes, ... }: {
    nixosConfigurations.mi-pc = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        loon-flakes.nixosModules.citron-nextendo
        { programs.citron-nextendo.enable = true; }
      ];
    };
  };
}
```

También se puede construir o ejecutar sin importar el módulo:

```bash
nix build github:loonbac/loon-flakes#citron-nextendo
nix run github:loonbac/loon-flakes#citron-nextendo
```

En una CPU compatible con x86-64-v3 se puede usar la build optimizada:

```bash
nix run github:loonbac/loon-flakes#citron-nextendo-v3
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
| `Fn+F6` / `Fn+F7`   | Bajar/subir brillo (backend propio por host)     |
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
samba), `file-roller` (integración gráfica de archivos comprimidos) y `p7zip`
(soporte para abrir y extraer 7-Zip) en `systemPackages`, y habilita
`programs.dconf` para los settings GTK.

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

El paquete local `pkgs/equibop-voice-normalizer/` añade normalización de
recepción por participante. Usa el `voiceDb` individual de Discord, descarta
silencio bajo `-55 dB`, suaviza 30 muestras y ajusta sólo el volumen local del
usuario entre 35 % y 200 %. Durante una llamada aparece el control `N -24 dB`:
permite activar/pausar el normalizador y mover el objetivo entre `-36 dB` y
`-12 dB`; la preferencia se conserva en el almacenamiento local de Discord.
Al salir del canal o desactivarlo se restauran los volúmenes anteriores.

En Linux, el paquete también asigna a los flujos de sonido la identidad
`Equibop` en PulseAudio/PipeWire y mantiene `AudioService` dentro del proceso.
Esto evita que OBS y los mezcladores lo agrupen con Pear Desktop u otras
aplicaciones Electron bajo el nombre genérico `electron`/`Chromium`.

El overlay local de voz para OBS escucha únicamente en loopback. La vista
compacta está en `http://127.0.0.1:5123/` (618×236) y la vista para la escena
Jugando en `http://127.0.0.1:5123/jugando` (1920×1080). Esta última distribuye
sin solapamientos a todos los hablantes en posiciones variables a lo largo del
borde inferior y deja el resto del lienzo transparente.

---

## Sistema (`modules/system/`)

- **Boot**: systemd-boot + UEFI.
- **Zona horaria / locale**: `America/Lima`, `es_PE.UTF-8`, teclado `es`.
- **Paquetes no libres**: `allowUnfree = true` (microcode Intel, etc.).
- **Brillo**: `loon-laptop` usa un wrapper setuid de `brightnessctl` sobre el
  panel interno Intel; `nixos-pc` usa DDC/CI sobre los buses I2C de la NVIDIA
  para el monitor principal GM3CC236. Waybar muestra el icono y porcentaje y
  permite regularlo con la rueda del mouse. En el PC un daemon de sesión
  agrupa las ráfagas de input y sincroniza el valor real cada 30 segundos.
- **Paquetes globales** (`environment.systemPackages`): git, gh, btop,
  fastfetch, ghostty, nodejs, zen-browser, vscode-insiders,
  equibop, fish, yazi, mpvpaper/mpv, oh-my-posh, los scripts propios
  (niri-cycle, loon-launch, rebuild, mpvpaper-wallpaper, niri-backdrop),
  Gentle-AI, Engram, Pi, Packet Tracer, `gentle-ai-bootstrap` y
  `gentle-stack-update`, además de
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
`niri-cycle`, `vscode-insiders`, `zen-browser`, `gentle-ai`, `engram`,
`engram-update`, `pi`, `gentle-ai-bootstrap`, `gentle-stack-update` y
`cisco-packet-tracer`, `steamidra`, `citron-nextendo`, `citron-nextendo-v3` y
`veadotube-mini`, `obs-pwvideo`.

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
  "nixos-pc"    = mkHost "nixos-pc" [ ];
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

## Notas sobre el host (`hosts/nixos-pc/`)

- Hostname: `nixos-pc` — ASRock B550 Pro4, Ryzen 7 5700X y GPU NVIDIA.
- Arranque UEFI con systemd-boot; raíz ext4 y ESP vfat declaradas por UUID.
- Microcode AMD y virtualización `kvm-amd` vienen de su hardware generado.
- El NVMe SK Hynix ext4 etiquetado `Compartido` se monta por UUID en
  `/home/loonbac/Proyectos`; es exclusivo de este host y usa `nofail`.
- El primer despliegue usa `nouveau`; el driver NVIDIA propietario se habilita
  en una migración posterior, después de confirmar el arranque gráfico estable.
- No hereda el disco extra, `i915`, VA-API `iHD`, tapa ni perfil de energía de
  `loon-laptop`.
- Estado: `26.05`.

## Notas de seguridad

- `PasswordAuthentication = false` → solo se puede entrar por **clave SSH**.
- `PermitRootLogin = "no"` → root no entra por SSH.
- El firewall está **activo** por defecto; para abrir puertos, ver
  `modules/networking/default.nix`.
- La contraseña de `loonbac` NO se guarda en este repo: se define con
  `passwd` en la máquina.
- Cisco Packet Tracer se incluye en `loon-laptop` (y su alias legado
  `korosoft`) mediante `pkgs/cisco-packet-tracer`, pero su `.deb` propietario
  debe aportarse manualmente y coincidir con el hash fijado. `nixos-pc` lo
  omite para poder reconstruirse desde un checkout limpio.

## ¿Por qué no hay `configuration.nix` ya?

Porque fue **reemplazado** por la estructura de flake. El archivo `/etc/nixos/configuration.nix`
ahora es un enlace simbólico hacia `~/.nixos/hosts/loon-laptop/default.nix` para que
`nixos-generate-config` y herramientas antiguas sigan funcionando; pero el flake
es la fuente de verdad. La configuración vieja quedó respaldada en
`~/.nixos/configuration.nix.bak` (no se versiona, está en `.gitignore`).
