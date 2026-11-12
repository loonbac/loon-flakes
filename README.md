# loon-flakes — La configuración de mis máquinas NixOS

Este repo tiene **todo lo que hace que mis dos máquinas funcionen igual**:
programas, escritorio, atajos, fondos, servicios y mis herramientas de IA.
Está organizado en **piezas chicas, cada una con un solo trabajo**, en vez de
un archivo gigante imposible de leer.

```
~/.nixos/
├── flake.nix                          # lista de dependencias + qué se instala
├── flake.lock                         # versiones exactas (no tocar a mano)
├── AGENTS.md                          # guía para agentes de IA que trabajan aquí
├── README.md                          # este archivo
├── pkgs/                              # programas propios hechos en casa
│   ├── rebuild/                       # el comando `rebuild` para aplicar cambios
│   ├── niri-cycle/                    # mover ventanas con salto infinito
│   ├── mpvpaper-wallpaper/            # fondo de pantalla animado (video en loop)
│   ├── niri-backdrop/                 # fondo de pantalla fijo
│   ├── gentle-ai-launcher/            # encuentra el Gentle AI correcto
│   ├── engram-launcher/               # arranca Engram (memoria de Pi)
│   ├── engram-updater/                # descarga Engram verificando que sea legítimo
│   ├── cline-launcher/                # arranca Cline
│   ├── pi-launcher/                   # arranca Pi
│   ├── pi/                            # extras de Pi (skills + apariencia)
│   ├── gentle-ai-bootstrap/           # deja todo instalado al iniciar sesión
│   ├── gentle-stack-update/           # actualiza Pi + extensiones + Engram
├── hosts/                             # lo propio de CADA máquina
│   ├── loon-laptop/
│   │   ├── default.nix                # identidad de la laptop: solo junta piezas
│   │   ├── platform.nix               # lo exclusivo del hardware Dell
│   │   ├── power.nix                  # modo batería / conectado (solo laptop)
│   │   └── hardware-configuration.nix # lo genera el sistema (NO tocar)
│   └── nixos-pc/
│       ├── default.nix                # identidad del PC: solo junta piezas
│       ├── platform.nix               # lo exclusivo del hardware AMD/NVIDIA
│       └── hardware-configuration.nix # lo genera el sistema (NO tocar)
└── modules/                           # piezas reutilizables (lo compartido)
    ├── default.nix                    # junta todos los módulos
    ├── system/                        # arranque, idioma, programas base
    ├── networking/                    # wifi y firewall
    ├── services/                      # servicios de fondo
    │   ├── openssh/                   # servidor SSH protegido
    │   └── tailscale/                 # red privada entre mis equipos
    ├── programs/                      # programas de uso diario
    │   ├── fish/                      # la terminal con linda presentación
    │   ├── ghostty/                   # la ventana de terminal
    │   ├── waybar/                    # la barra inferior con reloj, volumen…
    │   ├── equibop/                   # Discord con arreglo para llamadas con VPN
    │   └── gentle-ai/                 # Pi + Gentle AI + Engram
    ├── wayland/                       # el escritorio gráfico
    │   ├── niri/                      # el organizador de ventanas
    │   └── dms-greeter/               # la pantalla de inicio de sesión
    └── users/                         # mi usuario y grupos
```

---

## Qué incluye este sistema (en sencillo)

Si no quieres leer todo el README, esto es lo importante:

- **El repo es forkable.** Tu identidad sale de una sola opción
  (`loon.username`); lo personal (providers de IA, jueces, servidores MCP)
  está tras interruptores (`loon.personal.*`, apagados por defecto) y hay una
  plantilla en `hosts/ejemplo/` con guía paso a paso más abajo. Pones tu
  nombre, apagas lo personal y obtienes tu propio sistema con `git pull`
  sin miedo.
- **Cada uno pone sus propias claves de IA en su home** (archivos que solo
  lee su usuario). Nada de claves queda en este repo público.

---

## La idea: piezas chicas en vez de un monstruo

| Si vienes de programar…              | Aquí equivale a…                      |
|--------------------------------------|---------------------------------------|
| `flake.nix` (dependencias)           | la lista de compras del sistema       |
| `hosts/loon-laptop/default.nix`      | el punto de entrada: solo junta piezas|
| `modules/default.nix`                | el índice que importa todo            |
| `modules/services/openssh/`          | un módulo = una sola cosa             |
| `pkgs/niri-cycle/`                   | un programita hecho en casa           |
| `imports = [ ./foo ];`               | incluir la pieza `foo`                |
| `rebuild`                            | compilar + aplicar los cambios        |

---

## Comando `rebuild`: aplicar lo que cambiaste

En vez de escribir el comando largo de NixOS cada vez, este repo trae su
propio comando **`rebuild`**:

```bash
rebuild          # aplica tus cambios (el que más vas a usar)
rebuild dry      # prueba sin aplicar nada (simulacro)
rebuild update   # trae versiones nuevas de todo y aplica
```

- Funciona desde cualquier carpeta: solo entra a `~/.nixos`.
- Detecta en qué máquina estás y aplica su configuración; si el equipo no
  está declarado, se niega en vez de romper algo.
- Pide tu contraseña solo cuando va a aplicar cambios de verdad.
- Su código vive en `pkgs/rebuild/default.nix`.

Al aplicar, también se revisa que la configuración del escritorio (`niri`)
sea válida, usando un entorno limpio. Los archivos que niri necesita se crean
solos, así que una máquina recién instalada no depende de nada previo. Si
falta la imagen opcional del banner del launcher, se usa un degradado
integrado. Waybar, loon-launch y los servicios de niri se inician con tu
sesión y se recuperan solos si fallan.

> **Ojo**: `rebuild update` también actualiza el `flake.lock`, lo que trae
> las últimas versiones de Zen Browser y VS Code Insiders (ver abajo).

---

## Comando `nixos-ssh`: contraseña o clave para entrar por SSH

Un menú que te pregunta cómo quieres que se pueda entrar a tu máquina por SSH:
con contraseña o solo con clave (certificado). Aplica el cambio con el mismo
mecanismo que `rebuild`.

```bash
nixos-ssh        # menú: password | cert | cancelar
```

- Te muestra primero el modo actual.
- Guarda tu elección en `modules/services/openssh/ssh-auth-mode` y la aplica.
- Si algo falla al aplicar, vuelve al modo anterior solo.
- Si el archivo no existe o está raro, usa `cert` (lo seguro: solo claves).
- Su código vive en `pkgs/nixos-ssh/default.nix`.

---

## Clonar este flake para tu propia máquina

Este repo es personal pero cualquiera puede copiarlo: tu configuración vive
solo en `hosts/<tu-host>/` + una línea en el flake, y todo lo demás se
actualiza con `git pull` sin tocar lo tuyo.

```bash
# 1. Copia la plantilla y genera el hardware real de tu máquina
cp -r hosts/ejemplo hosts/mi-pc
nixos-generate-config --show-hardware-config > hosts/mi-pc/hardware-configuration.nix

# 2. En hosts/mi-pc/default.nix: pon tu hostname, tu loon.username y qué
#    áreas personales enciendes (todo apagado por defecto)
# 3. En flake.nix, nixosConfigurations: añade "mi-pc" = mkHost "mi-pc" [ ];
# 4. Si enciendes providers de Pi, crea TUS claves (solo-legibles-por-ti) en tu home:
#    ~/.config/inception/api-key, ~/.config/mistral-vibe/api-key, ...
# 5. Instala: sudo nixos-rebuild switch --flake .#mi-pc
```

- Con `loon.personal.enable = false` (lo que trae la plantilla) obtienes el
  sistema completo sin ningún dato de loonbac: ni su usuario, ni sus
  providers, ni sus MCPs. Cada área se enciende por separado (`piProviders`,
  `judges`, `mcpServers`) cuando copias esa área con tus propios archivos.
- Si creas un host no registrado en `loon.knownHosts` sin poner tu
  `loon.username`, la evaluación falla con un mensaje que te dice exactamente
  qué personalizar. Es a propósito: mejor un error claro que instalar el
  usuario de otro sin darte cuenta.
- Actualizar sin miedo: tus cambios viven en `hosts/<tu-host>/` y tu línea del
  flake. Un `git pull` solo puede rozar esos dos puntos; si hay conflicto, es
  ahí y se resuelve en un minuto.

---

## `loon-launch` — el lanzador (Super+Space) y los fondos (Super+B)

Es un lanzador de programas hecho en Rust, lindo y rápido. **Su código NO vive
en este repo**: está en
[`loonbac/loon-launch`](https://github.com/loonbac/loon-launch) y aquí solo se
consume como dependencia. Su historia y sus pruebas son suyas.

Siempre está corriendo en segundo plano: `Super+Space` abre programas;
`Super+B` (o `loon-launch wallpapers`) abre el selector de fondos.

**Ventana de programas (680×350)**

- Arriba: un banner de 180 px con una imagen y la caja de búsqueda encima.
- Abajo: lista en **2 columnas** de 4 filas (icono + nombre). Si hay más,
  se desplaza a la derecha (sin barra visible; con las flechas).
- `←/→` cambian de columna, `↑/↓` se mueven dentro, `Enter` abre el programa,
  `Escape` cierra. Escribir filtra; `>` son acciones de apagar/reiniciar/etc.

**Ventana de fondos (740×350)**

- Arriba: **Fondo de pantalla** (videos de `~/Videos/Wallpapers`, con vista
  previa en vivo). Si hay más de dos, `→` recorre la tira.
- Abajo: **Background** (fotos de `~/Pictures/Wallpaper`).
- `↑/↓` saltan entre las dos filas. `Enter` aplica el fondo.

Para cambiar el lanzador se edita **en su repo**; aquí solo se trae la versión
nueva actualizando la dependencia y aplicando:

```bash
cd ~/Proyectos/loon-launch
nix develop --command cargo test
# ... commit y push ...
cd ~/.nixos && nix flake update loon-launch && rebuild
```

Para revisar que todo sigue bien: `niri validate --config modules/wayland/niri/config.kdl`
y `nix build .#loon-launch --no-link --print-out-paths`.

---

## Programitas del flake (`pkgs/`)

### `niri-cycle` — mover ventanas con salto infinito (Super+←/→)

En niri las ventanas se ordenan en columnas. Este script mueve la ventana a la
columna de al lado, y si estás en el borde, salta al otro extremo (da la vuelta).

### `mpvpaper-wallpaper` — fondo animado (Super+B)

Pone un video en loop detrás de las ventanas:

```bash
mpvpaper-wallpaper              # reproduce el video elegido (o el primero)
mpvpaper-wallpaper set NOMBRE   # elige un video de ~/Videos/Wallpapers
mpvpaper-wallpaper list         # lista los videos disponibles
mpvpaper-wallpaper pause [MOTIVO] [DUEÑO]  # pausa y deja el último cuadro
mpvpaper-wallpaper resume [MOTIVO] # quita ese motivo; sin motivo los quita todos
mpvpaper-wallpaper reasons      # qué lo tiene pausado, desde cuándo y por quién
mpvpaper-wallpaper reconcile    # limpia pausas de procesos que ya murieron
mpvpaper-wallpaper status       # dice si está sonando, pausado o detenido
mpvpaper-wallpaper stop         # lo detiene
```

Al cambiar de video no hay corte brusco: mantiene el anterior y funde el nuevo
encima en 0.8 segundos.

Se inicia solo al entrar a la sesión. Su comunicación interna vive en tu carpeta
de usuario con permisos privados; no usa `/tmp` compartido.

La pausa funciona por **motivos acumulados**: el video solo se detiene mientras
quede al menos uno. Hay dos que se ponen solos: `opaque-window` (cuando la
ventana que miras tapa todo el fondo — las transparentes como ghostty no
cuentan) y `power-profile` (cuando la laptop entra en ahorro de batería).

Cada motivo guarda **cuándo** se puso y **quién** lo puso. `reasons` te muestra
esas tres columnas para que una pausa olvidada no se confunda con una ventana
tapando el fondo:

```
$ mpvpaper-wallpaper reasons
manual	3d2h	cli
opaque-window	12s	pid:2841 (huérfano)
```

Si el proceso dueño de un motivo muere (se reinició el observador, se mató el
ahorro de energía a la fuerza), su motivo queda colgado y el fondo se pausa
para siempre. `reconcile` limpia esos huérfanos, y solo reanuda si quitó el
último. `reasons` y `status` solo informan, nunca cambian nada. Tus pausas
manuales (`cli`) nunca se quitan solas: `resume` sin argumentos las borra todas.

### `accent-wallpaper` — el color del sistema sale de tu fondo

Toma el color más llamativo de tu video de fondo y lo usa como color de acento
(borde de la ventana activa + detalles de la barra). Usa `ffmpeg` para sacar un
cuadro e `imagemagick` para buscar el color más vivo:

```bash
accent-wallpaper             # analiza el video actual
accent-wallpaper from VIDEO  # analiza un video específico
```

Guarda el color en `~/.config/mpvpaper/accent.txt` y `~/.config/niri/accent.kdl`
(niri lo recarga en vivo al cambiar). Tanto el fondo animado como el fijo lo
disparan solos al cambiar; waybar y Pi actualizan sus colores sin reiniciar.

### `niri-backdrop` — fondo fijo global

Pone una imagen fija como fondo global (se ve detrás de todo, incluso a través
de las ventanas transparentes). Imágenes en `~/Pictures/Wallpaper`:

```bash
niri-backdrop              # pone la imagen elegida (o la primera)
niri-backdrop set IMAGEN   # elige una imagen
niri-backdrop stop         # quita el fondo
```

### Gentle-AI + Pi + Engram — lo declarado vs lo actualizable

El módulo `modules/programs/gentle-ai/` separa dos cosas:

- **NixOS declara** los lanzadores, los modelos por defecto, las rutas y las
  preferencias. Eso sí está versionado.
- **Los programas se actualizan solos**: Pi vive en
  `~/.local/share/loon-pi/npm-prefix` como una instalación normal que puedes
  actualizar, fuera del almacén inmutable de Nix. Lo mismo Engram en
  `~/.local/share/loon-engram`.

`gentle-pi` trae dentro el binario exacto y verificado de Gentle AI con el que
funciona; no hay una segunda copia fijada por Nix. `gentle-ai-bootstrap` se
ejecuta al iniciar sesión (y a mano cuando quieras): en una máquina nueva
instala solo lo que falta y **nunca** actualiza por sorpresa lo que ya tienes.
Al migrar, retira de forma recuperable los enlaces viejos y los guarda en
`~/.pi/agent/backups/`.

El bootstrap mantiene el tema, el proveedor/modelo principal y las rutas de
subagentes, pero **no toca** tus credenciales, sesiones ni la memoria de
Engram. El origen del núcleo Gentle se elige aparte en el módulo NixOS: esas
opciones solo eligen `gentle-pi`, el runtime y el binario de Engram, nada de
tus cosas personales.

```nix
programs.gentle-ai.core = {
  gentlePi = {
    # release usa npm; git usa el repositorio oficial de gentle-pi.
    mode = "release";
    ref = null;
    # mode = "git"; ref = "mi-rama";
    # mode = "release"; ref = "2.7.0";
  };

  # null usa el programa verificado que instala gentle-pi.
  # Para probar una rama se usa la variable oficial, no se escribe a mano.
  gentleAi.source = null;

  engram = {
    # release + null sigue siempre la última estable. Un ref explícito
    # es solo para una prueba puntual, pedida a conciencia.
    mode = "release";
    ref = null;
  };
};
```

El plugin de Engram para Pi se declara como `npm:gentle-engram`, sin versión:
Pi lo instala en su carpeta y `pi update --extensions` lo actualiza como
cualquier extensión. Engram mantiene su canal aparte (`release:latest`).
Un rebuild solo verifica que existan; no reemplaza ni rebaja lo instalado.
`gentle-stack-update` actualiza todo lo móvil de forma explícita y después
reconcilia la configuración.

Los subagentes trabajan en modo interactivo por defecto. Para ver o cambiar si
una tarea en segundo plano puede despertar a Pi sola:

```bash
/gentle:background-subagents status
/gentle:background-subagents disable
```

Con eso apagado, las preguntas del subagente pasan por la pantalla de Pi. El
modo `background` sigue disponible si lo pides a mano; como no hay pantalla
que responda, sus preguntas se cancelan.

```bash
gentle-ai-bootstrap
gentle-ai version
engram version
pi --version
gentle-ai doctor
```

#### Actualizaciones: nada se fija a mano

La regla del repo es **no congelar versiones de aplicaciones a mano**. NixOS
declara qué instalar; `flake.lock` + `rebuild update` traen lo nuevo; cada
programa mutable se actualiza por su propio mecanismo. Los pins viejos que
quedan son deuda, no ejemplo a seguir.

```bash
pi update                 # solo Pi
pi update --extensions    # gentle-pi y demás extensiones
engram update             # solo Engram
gentle-stack-update       # todo el stack + configuración
```

`gentle-stack-update` también actualiza CodeGraph. Un rebuild solo instala su
programa si falta; respeta la versión que ya tienes.

Actualizar con el lanzador `pi` dispara al terminar `gentle-ai-bootstrap`:
conserva lo recién instalado y solo reaplica la configuración. La versión
real queda anotada en `~/.pi/agent/nix/gentle-core-observed.json`.

Los avisos de Pi llegan al escritorio: cualquier pregunta o pantalla que un
plugin abra mientras trabajas genera una notificación en SwayNC con sonido.
Cuando termina una petición completa, otro aviso. El puente se instala solo en
`~/.pi/agent/extensions/loon-notifications.ts` y no se pierde al actualizar.
El sonido es el WAV versionado en `pkgs/pi/assets/snd_pi_attention.wav`.
Completar un subagente interno **no** avisa; una pregunta que llegue a tu
pantalla principal, sí. Las preguntas usan aviso normal, los permisos aviso de
alerta, y solo el final usa aviso informativo. Los menús que abras a mano se
ignoran. Ghostty ignora el pitido auxiliar para no sonar dos veces.

Pi, Gentle y Engram se actualizan por sus propios mecanismos
(`pi update`, `engram update`, `gentle-stack-update`); el inicio de sesión
solo repara lo que falte y nunca toca tus sesiones, tu `~/.engram/` ni tus
claves. Los detalles finos de providers y respaldos viven en el código del
módulo, no aquí.

Gentle Shell también viene declarado: por defecto siempre lo último
(`programs.gentle-ai.gentleShell`, canal `release`); `version = "x.y.z"` lo fija
 y `channel = "main"` lo compila desde fuente. `gentle-shell upgrade`
avanza, `--channel X` cambia (apunta el .nix para que dure) y `--rollback`
vuelve a la versión anterior.

### Veadotube Mini

Veadotube Mini 2.2 viene como binario externo, solo para `nixos-pc`. Su ZIP de
itch.io usa enlaces que caducan y no se guarda en Git; el paquete fija nombre y
código SHA-256 en `pkgs/veadotube-mini/default.nix`. Antes del primer rebuild,
mete el ZIP exacto al almacén:

```bash
nix store add --mode flat --hash-algo sha256 \
  --name veadotube-mini-linux-x64.zip \
  /ruta/a/veadotube-mini-linux-x64.zip
rebuild
```

El paquete conserva su estructura y aporta las librerías que necesita en NixOS.
Queda instalado con su icono, así que después puedes borrar el ZIP. Se activa
solo en `hosts/nixos-pc/streaming.nix` con `programs.veadotube-mini.enable`.

### Fuente de video PipeWire para OBS

`obs-pwvideo` agrega a OBS una fuente genérica de video PipeWire (sirve para
recibir video de herramientas como libfunnel sin usar el portal de captura).
Se compila desde un commit fijo de su proyecto original y se instala con el
mecanismo oficial de OBS; no copia nada a `~/.config/obs-studio`. Solo en
`nixos-pc`, desde `hosts/nixos-pc/streaming.nix`.

Ese mismo archivo, solo en `nixos-pc`, le dice al OBS dónde están las
librerías del driver NVIDIA para que aparezcan los codificadores NVENC de la
RTX 3060. Las demás máquinas no heredan nada de NVIDIA.

El PC también trae `obs-pipewire-audio-capture`: fuentes PipeWire para grabar
por separado una app, una entrada o una salida de audio. Solo declarado en
`streaming.nix`; no afecta a otras máquinas.

El PC incluye además la fuente **Captura de aplicación (Niri)**: lista todas
las ventanas y recuerda la app por su nombre interno. Usa el mecanismo oficial
de niri: autorizas una sola vez al crear la fuente y después OBS la restaura
sola. Si la app está cerrada, la fuente queda vacía; cuando la abres, se
reconecta sola.

Es la forma estándar de capturar apps completas en `nixos-pc`. No necesita
nada por programa y sirve para cualquiera. Como niri comparte un solo
«objetivo» entre fuentes, está pensada para la app o juego activo, no para dos
ventanas a la vez.

### Voz GLaDOS para Twitch (TTS en OBS)

`pkgs/obs-twitch-glados-tts/` instala un script de OBS que escucha el comando
`!t` en el chat de `#loonbac21` y lo lee en voz alta con la voz GLaDOS en
español, todo en tu máquina (sin bots ni cuentas extra). Los audios temporales
se crean y se borran solos.

Al abrir OBS, el script se registra solo y crea la fuente `Twitch GLaDOS TTS`
con su propio volumen en el mezclador. Canal, comando, límites, volumen y
velocidad se ajustan en **Herramientas → Scripts** y se aplican en vivo.

### TikTok LIVE: chat y alertas para OBS

`pkgs/obs-tiktok-live/` instala otro script de OBS, solo `nixos-pc`. Al abrir
OBS se registra y arranca el servicio local. Las pantallas se crean a mano en
la escena que quieras: **TikTok Chat** (600×900) con
`http://127.0.0.1:5124/chat`, y **TikTok Alerts** (1920×1080) con
`http://127.0.0.1:5124/alerts`.

En **Herramientas → Scripts → TikTok LIVE** escribes el usuario, con o sin
`@`. Recibe chat, regalos (rachas agrupadas en una sola alerta), follows,
compartidos, entradas y likes. Todo es local: no hay puertos abiertos, bots ni
claves en el repo. Si la cuenta no está en vivo, reintenta solo.

TikTok no da una API oficial para esto: el conector usado observa lo mismo que
ve cualquier espectador y puede necesitar actualización si TikTok cambia algo;
leer un directo público no pide iniciar sesión. La presentación y las URLs son
locales y nunca salen del PC.

Para probar el chat sin transmitir, crea una fuente temporal de **634×604** con
`http://127.0.0.1:5124/chat?demo=1`: muestra mensajes falsos sin conectarse;
la fuente real sigue usando `/chat` sin ese parámetro.

Hay dos vistas chicas de **320×46** para poner a mano en escenas de actividad:
la de follow guarda el último que siguió; la de regalo muestra quién, qué y
cuántos (ej. `Luna · Rosa ×3`). No se crean solas: usan
`http://127.0.0.1:5124/activity/follow` y
`http://127.0.0.1:5124/activity/gift`.

### Si formateas: qué guardar del streaming en `nixos-pc`

El flake reconstruye OBS y todo lo suyo solo. No copies plugins a mano a
`~/.config` ni `~/.local/share`. Lo personal no está en Git: para recuperar tu
disposición y cuentas después de formatear, guarda en privado:

- `~/.config/obs-studio/basic/`: escenas, perfiles y servicio de streaming.
- `~/.config/obs-studio/global.ini`, `user.ini` y, si personalizaste su panel,
  `plugin_config/audio-monitor/config.json`.
- `~/OBS/Escenas/`: HTML, imágenes y archivos locales de tus fuentes.
- `~/.veadotube/data/mini/autosave.veado`: tu personaje actual.
- El ZIP original `veadotube-mini-linux-x64.zip` 2.2 con hash
  `sha256-JHgC9nhMTr76zavmj8kzmdTyOwWFdSJ1lEpx26yAnrA=`. Itch.io usa enlaces
  que caducan y Nix no puede descargarlo solo.

Equibop y Pear: puedes iniciar sesión de nuevo; si quieres evitarlo, sus datos
privados están en `~/.config/equibop` y `~/.config/YouTube Music`. Los audios
del TTS y el estado del overlay son temporales y no se respaldan.

### Sunshine (jugar en otro lado)

`sushine.nix` comparte la pantalla del PC para clientes Moonlight. Solo se
mantiene prendido mientras `dolphin-emu` corre; al cerrar el emulador, se
apaga solo.

### Drift (editar video)

`creator.nix` instala Drift (editor de CutWire Studios) desde Flathub por su
ID oficial: sin versión fijada ni archivos propios. Los permisos que necesita
ya vienen en su manifiesto y los medios entran por portales.

### Compilación cruzada ARM + respaldos MDM (solo PC)

`cross-toolchain.nix`: toolchain `armv7l` para compilar desde el PC lo que
corre en la caja rk322x (proyecto ressy-tv), que no puede compilar sola.
`mdm-respaldo.nix`: respaldos del stack de contenedores MDM a `/var/backups/mdm`.

### Citron Nextendo

El input `citron-nextendo` consume el flake público e independiente
[`loonbac/citron-nextendo-nix`](https://github.com/loonbac/citron-nextendo-nix).
Cuando Nextendo Network publica una versión Linux que funciona, ese repo
verifica sus códigos y guarda sus tres AppImages tal cual bajo una etiqueta
fija. No trae ni compila el código de Citron; solo ofrece el paquete y el
módulo para Linux de 64 bits (normal, optimizado v3 y ARM).

Citron Nextendo no está en nixpkgs. Se instala directo desde el flake:

```bash
nix profile install github:loonbac/citron-nextendo-nix#citron-nextendo
```

En CPU compatible con x86-64-v3 (como el Ryzen 7 5700X del PC), la versión
optimizada:

```bash
nix profile install github:loonbac/citron-nextendo-nix#citron-nextendo-v3
```

El PC usa la optimizada. Una actualización entra con `rebuild update`, que
avanza el input; un rebuild normal conserva la versión instalada.

Otro flake NixOS puede reutilizar el módulo directamente:

```nix
{
  inputs.citron-nextendo.url = "github:loonbac/citron-nextendo-nix";

  outputs = { nixpkgs, citron-nextendo, ... }: {
    nixosConfigurations.mi-pc = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        citron-nextendo.nixosModules.default
        { programs.citron-nextendo.enable = true; }
      ];
    };
  };
}
```

También se puede probar sin instalar el módulo:

```bash
nix build github:loonbac/citron-nextendo-nix
nix run github:loonbac/citron-nextendo-nix
```

En CPU compatible, la optimizada:

```bash
nix run github:loonbac/citron-nextendo-nix#citron-nextendo-v3
```

---

## Escritorio: niri + pantalla de login

### niri (`modules/wayland/niri/`)

Es el programa que organiza tus ventanas (scrollable-tiling). Su configuración
`config.kdl` se maneja desde NixOS: vive en `/etc/niri/config.kdl` y tu
`~/.config/niri/config.kdl` es un enlace. **No edites `~/.config/niri` a
mano**; edita el repo y corre `rebuild`.

Lo principal de la config:

- **Ventanas**: ocupan todo el ancho, con espacios de 16px, esquinas
  redondeadas y borde fino (sin fondo sólido para no tapar transparencias).
- **Fondo transparente**: deja ver el wallpaper que está detrás.
- **Teclado**: distribución `es`, numlock prendido. Touchpad con toque y clic.
- **Portapapeles que no se pierde**: al cerrar la app de donde copiaste, lo
  copiado se conserva (imprescindible para pegar capturas después de cerrar).
- **Historial del portapapeles**: guarda textos e imágenes que copiaste y
  `Super+Shift+V` te deja recuperarlos (arregla el bug de Chromium/Electron
  que no pega imágenes, p. ej. en Equibop/Discord).
- **Color de acento**: el borde de la ventana activa usa el color de tu fondo
  (lo calcula `accent-wallpaper` solo).
- **Modo oscuro global** para GTK y apps Electron.
- **ghostty transparente de verdad**: el compositor la deja ver el fondo
  (opacidad 0.8 + efecto xray).

#### Atajos de teclado

| Tecla               | Qué hace                                    |
|---------------------|---------------------------------------------|
| `Super+Return`      | Abrir la terminal (ghostty)                 |
| `Super+E`           | Abrir archivos (Nautilus)                   |
| `Super+Space`       | Abrir el lanzador (loon-launch)             |
| `Super+Q`           | Cerrar ventana                              |
| `Super+F`           | Agrandar/restaurar ventana                  |
| `Super+B`           | Elegir fondos                               |
| `Super+Shift+S`     | Captura de pantalla → portapapeles          |
| `Super+Shift+V`     | Pegar desde el historial                    |
| `Super+←` / `→`     | Mover ventana (da la vuelta al llegar al fin)|
| `Super+1..9`        | Cambiar de escritorio                       |
| `Fn+F6` / `Fn+F7`   | Bajar/subir brillo                          |
| `Fn+F2` / `Fn+F3`   | Bajar/subir volumen (±5%)                   |

### Pantalla de login (`modules/wayland/dms-greeter/`)

La pantalla para entrar es **DankMaterialShell** sobre niri. Su tema fino se
ajusta en `~/.config/DankMaterialShell/settings.json`.

---

## Servicios (`modules/services/`)

### OpenSSH (`openssh/`)

Servidor SSH **endurecido**: solo se entra con clave
(`PasswordAuthentication = false`), y root no puede entrar
(`PermitRootLogin = "no"`).

### Tailscale (`tailscale/`)

Tu red privada (WireGuard) para conectar tus equipos entre sí.

```bash
sudo tailscale up   # unir la máquina a tu red (una sola vez)
tailscale status    # ver el estado y tus equipos
```

El `ts-bypass` viejo de la laptop está apagado: se reemplazó por el túnel
Cloudflare de abajo.

### Túnel Cloudflare (`hosts/nixos-pc/cloudflared.nix` y laptop)

Acceso remoto por `bypass.loonbac-dev.moe` (SSH) sin abrir puertos. El token
vive en `/var/lib/cloudflared/token` (solo root) y **nunca** en el repo: el
módulo solo declara la carpeta, el archivo se pone a mano en cada máquina.
No detengas el servicio sin avisar: corta a quien esté conectado por ahí.

---

## Programas (`modules/programs/`)

### fish (`fish/`)

Tu shell (la línea de comandos) por defecto:

- Sin mensaje de bienvenida.
- **Encuentra programas solo**: agrega al PATH las carpetas que existan
  (`~/.npm-global/bin`, `~/.cargo/bin`, `~/.local/bin`, etc.) — lo que
  instales funciona sin configurar nada.
- **Linda presentación** con el tema *craver*, manejado por NixOS (vive en
  `/etc/oh-my-posh/craver.omp.json`, versionado en el repo).

### ghostty (`ghostty/`)

La ventana de terminal, configurada por NixOS (igual que niri: el archivo real
está en `/etc/ghostty/config` y el tuyo es un enlace):

- Sin barra de título.
- Margen interno de 12px.
- Fondo opaco; la transparencia la pone niri.
- Atajos: `ctrl+shift+t` nueva pestaña, `ctrl+shift+w` cerrar pestaña,
  `ctrl+shift+,` recargar config sin cerrar nada.

### nautilus (`nautilus/`)

El explorador de archivos de GNOME. En NixOS 26.05 su opción oficial se quitó,
así que el módulo instala `nautilus` + `gvfs` (montar discos, papelera, red),
`file-roller` (abrir comprimidos con clic) y `p7zip` (soporte 7-Zip), y prende
`programs.dconf` para los ajustes visuales.

### wine (`wine/`)

Para correr programas de Windows (32 y 64 bits), más `winetricks` y doble clic
para `.exe` y `.msi`. Desde terminal:

```bash
wine-exe programa.exe [argumentos]
```

Un `.exe` con permiso de ejecución también corre como `./programa.exe`. No
todo programa Windows funciona con Wine; los que pidan librerías extra se
preparan con `winetricks`.

### waybar (`waybar/`)

La barra inferior (reloj, volumen, red, brillo, batería, ventanas…),
configurada por NixOS (archivos reales en `/etc/waybar/`, los tuyos son
enlaces). Arranca sola con la sesión.

- **Editar**: `modules/programs/waybar/config.jsonc` (qué muestra) y
  `modules/programs/waybar/style.css` (cómo se ve) → `rebuild`.
- **Recargarla** sin cerrar sesión: `killall waybar && waybar &`.

### equibop (`equibop/`)

Cliente de Discord **Equibop** con un arreglo para que las llamadas de voz
funcionen con Tailscale (o cualquier VPN) prendida. Su autoarranque lo maneja
NixOS.

**El problema**: con VPN activa, las llamadas se quedan colgadas en
*"DTLS Connecting"* porque el audio intenta salir por la interfaz equivocada.

**El arreglo**: en cada instalación se mete un pequeño gancho en el programa
que le dice al audio usar las interfaces normales
(`default_public_and_private_interfaces`, el mismo arreglo de
[Vesktop PR #1283](https://github.com/Vencord/Vesktop/pull/1283)).

> **OJO**: la opción de Chromium `--webrtc-ip-handling-policy` NO sirve
> (Equibop la ignora). El valor `disable_non_proxied_udp` tampoco (deja la
> llamada en *"RTC Connecting"*). El único que funciona con VPN es
> `default_public_and_private_interfaces`.

El paquete `pkgs/equibop-voice-normalizer/` empareja el volumen de todos los
que hablan: mide cada voz y la ajusta (hasta +18 dB), así el 200 % de Discord
amplifica de verdad. Ignora silencios, atenúa rápido, sube despacio y al salir
del canal todo vuelve como estaba. Pruebas:
`node --test pkgs/equibop-voice-normalizer/normalizer.test.cjs`.

Además hay push-to-talk global (`pkgs/equibop-mic-hotkey/`, se puentea al
programa en cada instalación) y el overlay de voz para OBS ya descrito arriba
(`pkgs/equibop-obs-overlay/`).

En Linux además se identifica como `Equibop` ante el sistema de sonido, para
que OBS y mezcladores no lo confundan con otras apps Electron.

El overlay de voz para OBS solo escucha en tu máquina: vista compacta en
`http://127.0.0.1:5123/` (618×236), vista de llamada en
`http://127.0.0.1:5123/llamada` (para fuente de 424×270) y vista de juego en
`http://127.0.0.1:5123/jugando` (1920×1080). La de llamada muestra hasta dos
avatares grandes centrados; la de juego reparte a todos por el borde inferior
dejando el resto transparente.

---

## Sistema (`modules/system/`)

- **Arranque**: systemd-boot + UEFI.
- **Idioma y zona**: `America/Lima`, español Perú, teclado `es`.
- **Programas no-libres permitidos** (`allowUnfree = true`): microcode Intel, etc.
- **Brillo**: en `loon-laptop` controla el panel interno Intel; en `nixos-pc`
  controla el monitor por cable (DDC/CI). Waybar muestra icono y porcentaje y
  deja ajustarlo con la rueda del mouse. En el PC un servicio junta los cambios
  y sincroniza el valor real cada 30 segundos.
- **Programas de todas las máquinas**: git, gh, btop, fastfetch, ghostty,
  nodejs, zen-browser, helium-browser, vscode-insiders, equibop, fish, yazi,
  mpvpaper/mpv, oh-my-posh, los programitas propios (niri-cycle, loon-launch,
  rebuild, mpvpaper-wallpaper, niri-backdrop), Gentle-AI, Engram, Pi,
  `gentle-ai-bootstrap`, `gentle-stack-update` y herramientas de diagnóstico.
- **Keyring**: necesario para que VS Code sincronice tus ajustes (su caja
  fuerte de secretos). Niri no lo prende solo, por eso se declara aquí.

## Red (`modules/networking/`)

- **NetworkManager** prendido (WiFi y cable por interfaz gráfica).
- **Firewall** prendido por defecto; para abrir puertos:
  `networking.firewall.allowedTCPPorts = [ ... ]` /
  `networking.firewall.allowedUDPPorts = [ ... ]`.

## Usuarios (`modules/users/`)

- Usuario `loonbac` (Joshua Rosales), grupos: `networkmanager` (red) y
  `wheel` (sudo). Shell: fish.
- **npm global**: la carpeta `~/.npm-global` se crea y se agrega al PATH (la
  de Nix es de solo lectura).

---

## Flake (`flake.nix`)

**De dónde viene cada cosa**:

| De dónde                   | Qué trae                                        |
|----------------------------|-------------------------------------------------|
| `nixpkgs`                  | la base `nixos-26.05`                           |
| `citron-nextendo`          | AppImages estables + su módulo                  |
| `zen-browser`              | Zen Browser (no viene en nixpkgs)               |
| `helium-browser`           | Helium Browser (no viene en nixpkgs)            |
| `code-insiders-flake`      | VS Code Insiders (se actualiza a diario)       |

**Programas que expone el flake**: `rebuild`, `loon-launch`, `niri-cycle`,
`vscode-insiders`, `zen-browser`, `helium-browser`, `gentle-ai`, `engram`,
`engram-update`, `pi`, `gentle-ai-bootstrap`, `gentle-stack-update`,
`steamidra`, `citron-nextendo`, `citron-nextendo-v3`, `veadotube-mini` y
`obs-pwvideo`.

**VS Code Insiders**: el flake original solo publica un archivito (`meta.json`
con versión + código + enlace, actualizado a diario). Lo leemos y construimos
el paquete sobre el VS Code normal, quitando dos pasos que asumen cosas que
Insiders no trae. Así `rebuild update` siempre instala el último.

---

## Comandos útiles (sin el `rebuild`)

```bash
# Aplicar cambios (desde ~/.nixos)
sudo nixos-rebuild switch --flake .#loon-laptop

# Probar sin aplicar
sudo nixos-rebuild dry-run --flake .#loon-laptop

# Ver qué ofrece el flake
nix flake show
nix flake check

# Traer versiones nuevas de todo
nix flake update

# Probar un programita sin instalarlo
nix run .#rebuild
nix run .#loon-launch
```

---

## Cómo agregar un programa al sistema

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

2. Anótalo en `modules/services/default.nix`:

```nix
imports = [
  ./openssh
  ./tailscale
  ./docker
];
```

3. Aplica: `rebuild`

## Cómo agregar otro escritorio (ej. Hyprland)

1. Crea la carpeta `modules/wayland/hyprland/default.nix`:

```nix
{ config, lib, pkgs, ... }:
{
  programs.hyprland.enable = true;
}
```

2. Anótalo en `modules/wayland/default.nix`:

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

## Lo propio de la laptop (`hosts/loon-laptop/`)

- Es una Dell Inspiron 15 3520 con gráficos Intel Iris Xe.
- **Video por hardware** en OBS (QSV) con el driver `iHD`.
- **WiFi y Bluetooth Realtek**: traen su firmware, sin eso no hay WiFi. El
  Bluetooth arranca con la sesión.
- **Modo batería/AC solo de ella** (`power.nix`, nadie más lo usa). En batería:
  pantalla a 60 Hz, fondo animado pausado, procesador en ahorro, WiFi en
  ahorro, disco duro a reposo a los 15 min y varios ahorros más. Conectada:
  120 Hz y todo normal.
- **Cargador con rebote**: un temporizador espera 30 segundos ante las
  señales repetidas del cargador Dell, para no aplicar el perfil a medias.
- **Disco Toshiba**: reposo a los 15 minutos a propósito (descansa sin
  prender/apagar a cada rato). Nunca se desmonta ni se fuerza a dormir.
- **Bluetooth en batería**: solo se apaga si confirma que no hay nada
  conectado. Al enchufar, se prende solo.
- **USB**: el receptor KYE `0458:019d` no se suspende solo (evita lag). No hay
  regla USB general.
- Estado: `26.05`.

## Lo propio del PC (`hosts/nixos-pc/`)

- ASRock B550 Pro4, Ryzen 7 5700X y NVIDIA.
- Arranque UEFI; discos declarados por código único (UUID).
- El disco NVMe etiquetado `Compartido` se monta en `/home/loonbac/Proyectos`.
  Es solo de este host.
- Arranca primero con el driver libre (`nouveau`); el propietario de NVIDIA se
  prende después, cuando el arranque gráfico ya es estable.
- No hereda nada de la laptop (ni su disco extra, ni Intel, ni tapa, ni ahorro
  de energía).
- Estado: `26.05`.

## Seguridad

- Solo se entra por **clave SSH** (las contraseñas por SSH están apagadas).
- Root no entra por SSH.
- El firewall está **prendido** por defecto; para abrir puertos, ver
  `modules/networking/default.nix`.
- La contraseña de `loonbac` NO está en este repo: se pone con `passwd` en la máquina.

## ¿Por qué no hay `configuration.nix`?

Porque se **reemplazó** por esta estructura. El archivo
`/etc/nixos/configuration.nix` ahora es un enlace hacia
`~/.nixos/hosts/loon-laptop/default.nix` para que las herramientas viejas no
se pierdan; pero el flake es la fuente de verdad. La configuración anterior
quedó respaldada en `~/.nixos/configuration.nix.bak` (no se sube a Git).
