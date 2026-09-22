# AGENTS.md — loon-flakes (NixOS multi-host)

Guía para agentes/asesores que trabajen sobre la configuración de NixOS de las
máquinas **loon-laptop** y **nixos-pc**. Léelo completo antes de
tocar nada: contiene el contexto, los estándares de arquitectura, los flujos
exactos y las trampas aprendidas en el camino.

**Índice**

1. Contexto general
2. Estructura del repo
3. Estándares de arquitectura (manifiesto de modularidad)
4. Flujo estándar
5. Política obligatoria de versiones: no fijar aplicaciones
6. Tareas comunes
7. Lecciones aprendidas (gotchas)
8. Cheat sheet
9. Notas de seguridad

---

## Contexto general

- **Máquinas** (NixOS 26.05; dos hosts en `flake.nix` → `nixosConfigurations`):
  - `loon-laptop` (Dell, `192.168.0.2`) — portátil Intel, el único con `power.nix`.
  - `nixos-pc` (ASRock B550/Ryzen 7 5700X/NVIDIA, `192.168.0.10`) — escritorio
    y máquina principal.
- **Objetivo de paridad**: ambas máquinas comparten la misma configuración de
  usuario (apps, shell, terminal, temas, atajos, sesión). `nixos-pc` es la
  referencia —es donde más se usa y donde se ha añadido más software— y
  `loon-laptop` converge hacia ella. Solo difieren hardware, discos, monitores
  y energía, que viven en `hosts/<host>/`.
- **Roles**: `nixos-pc` = gaming + streaming (OBS con plugins, Sunshine y gaming
  se quedan solo ahí); `loon-laptop` = solo productividad (OBS queda pelado, sin
  gaming por ahora). Los servicios de batería (`power.nix`, `ts-bypass`,
  `moonlight-power`) son exclusivos de la laptop; la PC no los lleva.
- **Acceso SSH**: `ssh loonbac@192.168.0.2` o
  `ssh loonbac@192.168.0.10`, con la clave `~/.ssh/id_ed25519`
  (la máquina local ya tiene la clave en `authorized_keys`, **sin contraseña**).
  La autenticación por contraseña por SSH está **desactivada** (`PasswordAuthentication = false`).
- **Repositorio de config**: `~/.nixos` en la máquina remota, es un repo git
  cuyo remote es `https://github.com/loonbac/loon-flakes.git` (rama `master`).
- **`/etc/nixos`** son symlinks al directorio del host bajo `~/.nixos/hosts/` — la fuente de
  verdad es el repo, no `/etc/nixos`.
- **`rebuild`**: comando custom del sistema (definido en `pkgs/rebuild/`) que
  detecta el hostname y corre `sudo nixos-rebuild switch --flake .#<hostname>`
  desde `~/.nixos`.
  También acepta `rebuild dry` (dry-run) y `rebuild update` (flake update + switch).

## Estructura del repo (`~/.nixos`)

```
~/.nixos/
├── flake.nix                  # inputs, mkHost (composición) y outputs del flake
│                              #   (packages, overlays, nixosModules, nixosConfigurations)
├── flake.lock                 # lockfile (versionar, no tocar a mano)
├── README.md                  # doc de usuario
├── AGENTS.md                  # este archivo
├── pkgs/                      # 43 piezas propias: una carpeta = un concepto (regla 6)
│   ├── rebuild/               # comando custom `rebuild`
│   ├── loon-launch/           # launcher Rust (GTK4 + libadwaita): Cargo.toml, src/main.rs
│   ├── nixos-ssh/ ts-bypass/ laptop-power-profile/ moonlight-power/ ...
│   │                          #   operación de sistema, energía y red
│   ├── mpvpaper-wallpaper/ niri-cycle/ accent-wallpaper/ mac-plymouth/ ...
│   │                          #   wallpaper, niri y aspecto
│   ├── obs-*/ equibop-*/ veadotube-mini/ karaoke-separator/ steamidra/ ...
│   │                          #   streaming y gaming
│   └── pi*/ gentle-ai*/ engram*/ gga/   # stack de agentes (launchers mutables)
├── hosts/                     # identidad + hardware por máquina; solo compone
│   ├── loon-laptop/           # Dell: default.nix, platform.nix (Intel), power.nix (AC/batería),
│   │                          #   extras-disk.nix (disco Proyectos sda1) y
│   │                          #   hardware-configuration.nix (autogenerado, NO tocar)
│   └── nixos-pc/              # PC: default.nix, platform.nix (NVIDIA/lanzaboote), hardware...
│                              #   y por capacidad: games-disk, projects-disk, gaming,
│                              #   streaming, sunshine (*.nix)
└── modules/                   # módulos compartidos por ambos hosts
    ├── default.nix            # mod raíz: registra todo + aserción de tmpfiles
    ├── system/                # boot, locale, fuentes, systemPackages
    │   ├── brightness.nix     #   opción hardware.brightness: comando screen-brightness único en ambas máquinas
    │   ├── coredump.nix       #   política de coredump compartida
    │   └── plymouth.nix       #   splash de arranque
    ├── networking/            # networkmanager, firewall
    ├── services/              # openssh, tailscale (+ts-bypass), udisks2, nixos-updates,
    │                          #   moonlight-power
    ├── programs/              # 21 módulos: fish, ghostty, gtk, hyprlock, nautilus, swaync,
    │                          #   waybar, yazi, wine, virtualbox, waydroid, steam, steamidra,
    │                          #   veadotube-mini, equibop, gentle-ai, obs-studio, obs-pwvideo,
    │                          #   pi-ssh-clipboard, pear-desktop (Pear + sink virtual pear_twitch),
    │                          #   cisco-packet-tracer (opcional, deshabilitado)
    ├── wayland/
    │   ├── niri/              # compositor: config.kdl + session-services.nix (unidades sesión)
    │   └── dms-greeter/       # greeter DankMaterialShell
    └── users/                 # usuario loonbac, grupos
```

Cada módulo de `modules/programs/` sigue el mismo patrón: `default.nix` con la
configuración y reglas tmpfiles que enlazan `/etc/<app>/` → `~/.config/<app>/`
(ver gotchas de tmpfiles en Lecciones aprendidas).

---

## Estándares de arquitectura (manifiesto de modularidad)

El manifiesto del home (`~/AGENTS.md`, «Modularidad Cohesiva y Componentes
Reutilizables») aplica a este repo traducido a Nix: un **módulo** es un módulo
Nix, un **componente reutilizable** es un paquete de `pkgs/` y el **producto**
es la configuración del sistema. Regla central: juntar lo que cambia por la
misma razón y separar lo que tiene dueño, dependencias o ciclo de vida propios.

### Reglas

1. **Organización por capacidad.** `modules/` agrupa por subsistema (system,
   networking, services, programs, wayland, users) y cada host descompone sus
   capacidades en archivos nombrables (`gaming.nix`, `streaming.nix`,
   `sunshine.nix`, `games-disk.nix`). No crear archivos por crear: una
   capacidad pequeña cabe en el `default.nix` de su módulo.
2. **Una responsabilidad por módulo, con dueño claro.** Un módulo = una
   capacidad nombrable (ssh, tailscale, niri, steam). `modules/system/` se
   reserva a arranque, locale, keymap, fuentes y paquetes base; no debe
   acumular temas ajenos (asociaciones MIME, wrappers de apps concretas,
   toolchains de un proyecto...).
3. **La configuración de una máquina vive en `hosts/<host>/`.** Hardware,
   discos, servicios y políticas exclusivos de un host jamás viven en
   `modules/`. Ejemplo correcto: `hosts/nixos-pc/games-disk.nix`. Deuda hoy:
   `modules/system/extras-disk.nix` (disco de loon-laptop) en el árbol
   compartido.
4. **Los módulos compartidos no bifurcan por hostname.** Nada de
   `lib.mkIf (config.networking.hostName == ...)` dentro de `modules/` para
   decidir qué instalar: el módulo expone su interfaz (opción `enable`,
   parámetros) y el host compone lo que necesita. Deuda hoy: `tailscale`
   (ts-bypass), `moonlight-power`, `waybar`, `niri` y `system` bifurcan por
   hostname.
5. **Composición explícita.** La única capa de composición es `flake.nix`
   (`mkHost`) + `hosts/<host>/default.nix`: `mkHost` inyecta `./modules`
   completo y el host agrega sus extras (nixos-pc añade lanzaboote, nix-flatpak
   y citron-nextendo). Lo que un host necesita se declara ahí, no condicionado
   dentro de los módulos.
6. **`pkgs/` es el catálogo de piezas reutilizables.** Una carpeta por concepto
   con nombre semántico (`ts-bypass`, `mpvpaper-wallpaper`, `niri-cycle`);
   prohibido `utils/`, `helpers/`, `common/`. Compartir una pieza solo con
   consumidores reales; si solo la usa un host, puede vivir junto a su
   consumidor.
7. **Sin duplicación que evolucione junta.** Un paquete se declara una sola vez
   (en su módulo dedicado, no también en `systemPackages`); un
   `hardware-configuration.nix` no se copia entre hosts; el patrón de tmpfiles
   que enlaza `/etc/<app>` → `~/.config/<app>` se mantiene en un único lugar.
8. **Sin abstracciones para futuros imaginados.** Ni overlays/`nixosModules`
   exportados sin consumidor real, ni paquetes sin referencias, ni cargas
   pesadas activadas en todos los hosts sin necesidad: una capacidad pesada
   (virtualbox, waydroid, wine) se activa con opción `enable` o solo donde se
   usa.
9. **Verificación proporcionada.** Existe: `niri-config-check` (valida
   `config.kdl` en el build), `niri validate --config`, la aserción de tmpfiles
   multilínea (`modules/default.nix`) y tests unitarios de `pkgs/`
   (loon-launch, pi-ssh-clipboard, equibop-voice-normalizer). Obligatorio al
   tocar un módulo compartido: validar ambos hosts (`rebuild dry` o
   `nixos-rebuild build --flake .#<host>`). Falta: `checks` en `flake.nix`, así
   que `nix flake check` no evalúa los hosts.
10. **Cambios acotados.** Una tarea localizada no reorganiza el repo entero: las
    mejoras que no hacen falta para el objetivo se proponen aparte. La política
    de versiones de arriba manda siempre (sin pins manuales).

### Estado de cumplimiento (auditoría 2026-09-22, actualizado tras parity-phase1)

| Regla | Estado | Referencia |
| :--- | :--- | :--- |
| Organización por capacidad | Cumple | `hosts/nixos-pc/*.nix` y `modules/` por subsistema |
| Responsabilidad única | Parcial | `modules/system/default.nix` acumula ~290 líneas de temas ajenos |
| Config de host en `hosts/<host>/` | Cumple | `extras-disk.nix` movido a `hosts/loon-laptop/`; ts-bypass/moonlight-power activados solo desde la laptop |
| Sin branching por hostname | Cumple | `grep -rn "networking.hostName" modules/` sin resultados; sustituido por `hardware.brightness.backend`, `services.ts-bypass.enable`, `services.moonlight-power.enable` y `programs.cisco-packet-tracer.enable` |
| Composición explícita | Cumple | `mkHost` + `hosts/<host>/default.nix` (korosoft, host inexistente con import cruzado, fue eliminado el 2026-09-22) |
| `pkgs/` sin vertederos | Cumple | 43 paquetes con nombre por concepto; sin `utils/` ni `helpers/` |
| Sin duplicación | Incumple | `fish`/`ghostty`/`yazi`/`notepad-next` declarados dos veces; patrón tmpfiles repetido |
| Sin abstracciones muertas | Incumple | `pkgs/vision-cursor/` sin referencias; overlays exportados que `mkHost` no consume; virtualbox/waydroid/wine globales |
| Verificación proporcionada | Parcial | checks de niri/tmpfiles/tests sí; output `checks` del flake no |
| Cambios acotados | Práctica | se exige en cada tarea (sección 6.3 del manifiesto) |

### Deudas conocidas (orden de abordaje sugerido)

1. Dividir `modules/system/default.nix`: paquetes base vs. temas concretos.
2. Activar virtualbox/waydroid/wine/obs-studio solo donde se usan (opción
   `enable`).
3. Unificar `fish`/`ghostty`/`yazi`/`notepad-next`: declararlos solo en su
   módulo, no también en `systemPackages`.
4. Retirar `pkgs/vision-cursor/` (huérfano) y decidir si los
   overlays/`nixosModules` exportados tienen consumidor externo real (hoy son
   aliases de compatibilidad; si no los tiene, retirarlos).
5. Mover los puertos 5173/8080 del firewall al módulo/proyecto que los usa.
6. Añadir `checks.${system}` al flake para evaluar ambos hosts.

---

## Flujo estándar (aplica a casi todo)

1. **Editar** el archivo correcto en `~/.nixos` (ver "Tareas comunes").
2. **`git add -A`** — OBLIGATORIO: los flakes solo ven archivos *trackeados* por
   git. Si creaste un archivo nuevo y no lo agregas, el rebuild falla con
   `Path '...' is not tracked by Git`.
3. **Aplicar**: `sudo nixos-rebuild switch --flake .#<hostname>` (o `rebuild`).
4. **Commit + push**:
   ```bash
   git add -A
   git -c user.name="loonbac" -c user.email="loonbac@users.noreply.github.com" commit -m "feat: ..."
   git push origin master
   ```

> **sudo no interactivo por SSH**: usar `echo <PASSWORD> | sudo -S ...`. La
> contraseña NO se guarda en el repo (es público en GitHub) — pedirla al usuario.

---

## Política obligatoria de versiones: no fijar aplicaciones

El objetivo del repositorio es declarar **qué instalar y cómo integrarlo**, no
congelar manualmente la versión de aplicaciones que tienen un canal normal de
actualización. Esta política es obligatoria para cualquier agente:

- **No introducir nuevos pins manuales de aplicaciones** en módulos, launchers
  ni configuración: quedan prohibidos specs como `paquete@1.2.3`, tags de
  release fijos, commits usados como canal permanente, defaults con una RC
  concreta y lógica que reinstale o rebaje una versión mutable durante un
  rebuild o un arranque.
- Para software disponible en `nixpkgs`, declarar el atributo sin override de
  versión. Su actualización pertenece a `rebuild update` y a `flake.lock`.
- Para ecosistemas con actualizador propio (Pi/npm, Engram y equivalentes), Nix
  debe instalar un launcher estable y declarar el origen/canal sin versión; los
  bytes actualizables viven fuera de `/nix/store`. Un rebuild o reinicio debe
  conservar la versión instalada por el usuario y limitarse a reconciliar la
  configuración.
- Si falta un paquete mutable, instalar únicamente ese paquete desde su spec
  sin versión. Durante un rebuild queda prohibido usar actualizadores masivos
  como `pi update --extensions`: podrían alterar otros paquetes que ya estaban
  instalados. Los updates generales solo se ejecutan por petición del usuario.
- Para Git, preferir la rama/canal móvil solicitado (`main`, rama por defecto o
  equivalente), nunca convertir silenciosamente ese canal en un commit o tag
  fijo. Solo el usuario puede pedir explícitamente un pin temporal.
- Si una derivación Nix externa exige obligatoriamente `rev` y hash para ser
  reproducible, eso es una **restricción técnica del source**, no una política
  de versión de usuario. Antes de añadirla hay que preferir, en este orden:
  paquete de `nixpkgs`, instalador mutable oficial, o metadatos actualizados
  automáticamente (como `sources.json` + CI). Nunca usar un pin manual como
  sustituto permanente de un actualizador.
- `flake.lock`, `Cargo.lock`, `package-lock.json`, hashes de integridad y el
  campo `version` meramente informativo de paquetes locales no cuentan como
  pins prohibidos: son metadatos reproducibles. No se editan a mano para
  retener una aplicación en una versión antigua.
- Los pins históricos que ya existen son deuda técnica, **no precedentes**.
  Cuando se toque uno, evaluar migrarlo a `nixpkgs`, a un runtime mutable o a
  una actualización automatizada. No crear otro sin autorización explícita del
  usuario y sin documentar por qué ninguna alternativa móvil es viable.
- Antes de cerrar un cambio de instalación, comprobar que actualizar por el
  mecanismo normal, reiniciar y ejecutar un rebuild no provoquen un downgrade.

En particular, la declaración por defecto de Gentle/Pi usa fuentes sin versión:
`npm:gentle-pi`, extensiones npm sin sufijo de versión y Engram
`release:latest`. Las opciones `ref` existen para pruebas solicitadas; un agente
no debe rellenarlas con una versión fija por iniciativa propia.

---

## Tareas comunes

### Instalar un paquete (ej. "instala vlc")

1. Editar `modules/system/default.nix` → `environment.systemPackages`:
   ```nix
   environment.systemPackages = with pkgs; [
     git
     gh
     btop
     fastfetch
     ghostty
     vlc                # ← agregar aquí
     (pkgs.callPackage ../../pkgs/loon-launch { })
     (import ../../pkgs/rebuild { inherit pkgs lib; })
   ];
   ```
2. `git add -A` + `rebuild` + commit/push.
3. Buscar nombres: `nix search nixos <paquete>`.

### Configurar un servicio (ej. "configura ssh")

1. Editar `modules/services/openssh/default.nix` (ya existe) o crear
   `modules/services/<nuevo>/default.nix`.
2. Si es nuevo, registrarlo en `modules/services/default.nix` (`imports = [ ... ]`).
3. `rebuild` + commit/push.

### Toggle de autenticación SSH (`nixos-ssh`)

El servidor SSH tiene un modo de autenticación conmutable entre `password`
y `cert` (solo claves), leído de `modules/services/openssh/ssh-auth-mode`.
- Cambiarlo a mano: escribir `password` o `cert` en ese archivo y `rebuild`.
- Recomendado: usar el comando `nixos-ssh` (menú interactivo + aplica solo).
- El default del módulo (si falta el archivo/está inválido) es `cert` (seguro).

### Editar el launcher Rust (loon-launch)

- **Código**: `pkgs/loon-launch/src/main.rs` (Rust, GTK4 + libadwaita).
- **Dependencias**: `pkgs/loon-launch/Cargo.toml` — usa `gtk4 = "0.11"`,
  `glib = "0.22"`, `libadwaita = "0.9"`. **No bajar a 0.9/0.20**: rompe la
  compatibilidad con libadwaita (conflicto de `gtk4-sys`).
- **Al cambiar deps**: regenerar `Cargo.lock` con `cargo generate-lockfile`.
- **Compilar localmente** (la máquina local tiene cargo): `cargo check` en
  `pkgs/loon-launch/`. No subir el `target/` (está en `.gitignore`).
- **Empaquetado**: `pkgs/loon-launch/default.nix` (buildRustPackage + cargoLock).
- **Bind**: `Super+Space` en `modules/wayland/niri/config.kdl`.
- **Regla de ventana** (flotante centrado, no maximizada): window-rule de
  loon-launch en el config.kdl, **después** de la regla genérica.
- **Instalación limpia**: ningún recurso imprescindible puede depender de
  rutas privadas del home. El banner opcional usa un degradado integrado si
  `~/Descargas/cl_aesthetic_mix58.jpg` no existe; nunca volver a usar `expect`
  al cargar un recurso externo de presentación.

### Editar la config de niri

- **Archivo**: `modules/wayland/niri/config.kdl` — gestionado por NixOS:
  se instala en `/etc/niri/config.kdl` y `~/.config/niri/config.kdl` es un
  symlink (tmpfiles). **No editar `~/.config/niri` a mano**; editar el repo.
- **Validar**: `niri validate --config <ruta>` (hay `niri` instalado también en
  la máquina local).
- **Binds actuales**: `Super+Return` → ghostty, `Super+Space` → loon-launch.
  En XKB la tecla Enter se llama `Return`. `Super+Space` existe solo si se
  define; niri no tiene binds por defecto.
- **Brillo**: el comando `screen-brightness` ahora funciona en ambas máquinas
  (en la PC delega en `ddc-brightness`).

### Editar el perfil AC/batería de loon-laptop

- **Activación exclusiva**: `hosts/loon-laptop/power.nix`, importado solo por
  `hosts/loon-laptop/default.nix`. Nunca registrarlo en `modules/` ni en el
  agregador global.
- **Hardware**: `pkgs/laptop-power-profile/laptop-power-profile.sh`.
- **Sesión niri/mpvpaper**:
  `pkgs/laptop-power-profile/laptop-power-profile-session.sh`.
- **Wallpaper IPC**: `mpvpaper-wallpaper pause|resume|status`; el socket vive
  en `$XDG_RUNTIME_DIR/mpvpaper-wallpaper/mpv.sock`.
- **Aislamiento**: comprobar siempre ambos hosts y verificar que `nixos-pc` no
  tenga `laptop-power-profile.service` ni
  `laptop-power-profile-session.service`.

### Editar la plataforma de nixos-pc

- **Identidad/composición**: `hosts/nixos-pc/default.nix`.
- **Hardware y drivers**: `hosts/nixos-pc/platform.nix`.
- **Particiones detectadas**: `hosts/nixos-pc/hardware-configuration.nix`.
- Nunca importar `hosts/loon-laptop/power.nix` ni
  `hosts/loon-laptop/extras-disk.nix` desde este host.
- Validar ambos hosts: el PC no debe heredar el UUID extra, `i915`, `iHD` ni
  `laptop-power-profile`; la laptop debe conservarlos.

### Editar el fix de Equibop (WebRTC + Tailscale)

- **Archivo**: `modules/programs/equibop/default.nix` — override del paquete
  que parchea el `app.asar` (extrae, inyecta el hook en `dist/js/main.js` y
  reempaqueta con `asar` de nixpkgs).
- **El autostart** también lo gestiona el módulo (`/etc/equibop/autostart.desktop`
  + tmpfiles → `~/.config/autostart/equibop.desktop`).
- **Probar sin aplicar**: `nixos-rebuild build --flake .#loon-laptop` y
  verificar el hook en el asar:
  `grep -ao 'setWebRTCIPHandlingPolicy("[^"]*")' <store>/opt/Equibop/resources/app.asar`.
- **Si el voice chat se queda en "RTC Connecting"**: el valor está mal — usar
  `default_public_and_private_interfaces` (ver Lecciones aprendidas).

### Actualizar Citron Nextendo

- **Fuente externa**: el input `citron-nextendo` de `flake.nix` consume el flake
  público independiente `github:loonbac/citron-nextendo-nix`; este repo no
  compila ni refleja artefactos de Citron.
- **Paquete/módulo**: provienen de los outputs `packages`, `overlays` y
  `nixosModules` del flake externo. `loon-flakes` conserva aliases públicos por
  compatibilidad.
- **Activación exclusiva**: `hosts/nixos-pc/gaming.nix`, con la variante
  `x86_64_v3` para el Ryzen 7 5700X. No habilitarlo en los demás hosts.
- **Actualización automática**:
  `loonbac/citron-nextendo-nix/.github/workflows/update.yml` espera una release
  Linux oficial exitosa, verifica los SHA-256 de sus tres AppImages, los copia
  byte por byte a una release inmutable y actualiza sus hashes Nix.
- Para traer una release nueva a NixOS se usa el flujo normal `rebuild update`,
  que actualiza el input en `flake.lock`; un rebuild normal no hace downgrade.
- No compilar Citron localmente para validar este módulo. Probar solo la
  evaluación o el paquete AppImage ya publicado; el build C++ puede consumir
  decenas de GiB de RAM.

### Editar TS-Bypass de loon-laptop

- **Módulo/servicio**: `modules/services/tailscale/default.nix` define
  `ts-bypass-tunnel.service`, exclusivo de `loon-laptop`.
- **Comando**: `pkgs/ts-bypass/default.nix`; soporta
  `on|off|restart|status|logs` y valida el peer `nixos-pc`.
- **Estado persistente**: `/var/lib/ts-bypass/tailscaled.env`. Su presencia
  activa el túnel en el siguiente arranque; `ts-bypass off` lo elimina.
- **Peer relay**: `elastika-vps` escucha en UDP 41641 y su transporte normal
  de Tailscale usa UDP 41642. El grant central permite a `loon-laptop`
  (`100.81.168.104`) y `nixos-pc` (`100.73.247.39`) usar el relay
  (`100.93.232.28`). El relay queda siempre disponible; el toggle solo cambia
  el transporte del cliente de la laptop.
- Tailscale debe recibir **solo** `ALL_PROXY=socks5://127.0.0.1:1080`.
  Nunca configurar `HTTP_PROXY`/`HTTPS_PROXY` con esquema SOCKS5: el cliente
  DERP los trata como proxy HTTP, envía `CONNECT` y el SOCKS responde con EOF.
- Verificar con `ts-bypass status` y
  `tailscale ping --until-direct=false nixos-pc`.

### Habilitar Cisco Packet Tracer (cuando proceda)

- **Activación**: definir `programs.cisco-packet-tracer.enable = true;` en el
  `default.nix` del host correspondiente y correr `rebuild`.
- **Instalador propietario**: requiere aportar manualmente el `.deb` propietario
  que coincida con el hash fijado en `pkgs/cisco-packet-tracer/default.nix`
  (mediante `nix store add`).
- Intencionalmente **NO está instalado** en ningún host en este momento (módulo
  opt-in deshabilitado por defecto hasta que el usuario decida instalarlo).

---

## Lecciones aprendidas (gotchas)

- **Flake + git**: archivos nuevos sin `git add` → error "not tracked by Git".
- **"Git tree is dirty"**: aviso normal cuando hay cambios sin commitear; el
  rebuild funciona igual. Desaparece al commitear.
- **tmpfiles**: `L+` NO reemplaza un archivo regular existente (solo actúa si
  no existe o ya es symlink). Usar **ruta absoluta** (`/home/loonbac/...`),
  systemd no expande `~` en tmpfiles.
- **Home nuevo + tmpfiles**: antes de cualquier regla `L+` o `f` bajo el home,
  declarar el directorio padre con `d ... 0755 loonbac users -`. No depender
  de que una aplicación o una sesión previa haya creado `~/.config/*`.
- **Contenido multilínea + tmpfiles**: no insertar saltos de línea en una
  regla raw. Declarar el default en `/etc` y copiarlo solo si falta con `C`;
  una aserción global rechaza reglas multilínea durante la evaluación.
- **Niri desde cero**: el build incluye `niri-config-check`, que valida
  `config.kdl` con un HOME vacío y un `accent.kdl` mínimo. Tras aplicar, probar
  también `niri validate --config /etc/niri/config.kdl` en el host destino.
- **Procesos de sesión**: Waybar, SwayNC, loon-launch, Hypridle, udiskie y los
  watchers del portapapeles viven en `modules/wayland/niri/session-services.nix`.
  No volver a duplicarlos con `spawn-at-startup`; comprobarlos con
  `systemctl --user status loon-niri-session.target`.
- **scp**: no expande `~` en el destino → usar rutas completas
  (`loonbac@192.168.0.2:/home/loonbac/.nixos/...`).
- **niri KDL**: los booleanos se escriben `prop true` (no `prop=true`); los
  `match` son regex (usar `.*`, no `*`).
- **GTK4 (Rust)**:
  - `connect_key_press_event` no existe en `Entry` → usar `EventControllerKey`
    (agregarlo a la ventana para que Escape funcione en todo el launcher).
  - `connect_focus_out_event` no existe → usar `EventControllerFocus` con
    `connect_leave` para cerrar al hacer click fuera.
  - Sintaxis de `clone!` (glib ≥0.22): `clone!(#[strong] x, move |...| ...)`
    — NO usar `@strong` (sintaxis vieja que ya no compila).
  - `next_sibling()`/`prev_sibling()` devuelven `Widget` → hacer
    `.downcast::<ListBoxRow>()` antes de `select_row`.
  - `StyleManager::default()` devuelve `StyleManager` (no `Option`).
- **greeter dms-greeter**: usa el compositor niri (instalado a nivel de
  sistema, no home-manager); `configHome = "/home/loonbac"` sincroniza el tema.
- **El rebuild puede tardar** (compila niri, loon-launch, quickshell) — usar
  timeouts generosos (600000 ms).
- **Citron Nextendo**: upstream reemplaza y borra la release mutable
  `nightly-linux`. El flake externo conserva sus AppImages oficiales byte por
  byte en una release inmutable por commit; no recompilar Citron ni fijar
  permanentemente el URL mutable de upstream.
- **Equibop + Tailscale → "DTLS Connecting"**: el voice chat se cuelga si
  WebRTC se bindea a la interfaz de la VPN. El fix vive en
  `modules/programs/equibop/default.nix` y **parchea el `app.asar`** (inyecta
  `setWebRTCIPHandlingPolicy("default_public_and_private_interfaces")` en
  `dist/js/main.js`). Gotchas aprendidos:
  - La bandera `--webrtc-ip-handling-policy` de Chromium **NO sirve** — Equibop
    no la lee; hay que llamar la API de Electron desde el proceso main.
  - El valor `disable_non_proxied_udp` **NO sirve** — deja la llamada en "RTC
    Connecting" (desactiva el UDP directo). Usar
    `default_public_and_private_interfaces` (el de Vesktop PR #1283).
  - Si Equibop cambia la estructura del bundle al actualizar, el parche puede
    fallar: verificar que `dist/js/main.js` exista en el asar y ajustar.
- **TS-Bypass**: `ALL_PROXY` usa el dialer SOCKS nativo de Tailscale. No
  duplicarlo en `HTTP_PROXY`/`HTTPS_PROXY`; esos nombres seleccionan la ruta
  HTTP CONNECT y causan `derphttp ... unexpected EOF` contra `ssh -D`.
- **`switch` en vivo vs `boot`**: nunca correr `nixos-rebuild switch` en una
  máquina que el usuario esté usando sin avisar: la activación re-servicia
  unidades y puede tumbar la sesión, la red y el wallpaper (incidente
  2026-09-22). Preferir `nixos-rebuild boot` (aplica en el próximo arranque,
  cero interrupción) o `test`, y avisar siempre antes de una activación en vivo.
  Si un `switch` es inevitable, lanzarlo desacoplado (`setsid nohup`):
  `nixos-rebuild` ejecuta `switch-to-configuration` vía `systemd-run --pipe`, y
  si la conexión del cliente muere (p. ej. un timeout de SSH) el pipe se cierra y
  **systemd interrumpe la activación a mitad**, dejando unidades detenidas sin
  re-arrancar (así quedó NetworkManager en el incidente del 2026-09-22).
- **Primera activación de `monitor.kdl`**: cuando se habilita `include "monitor.kdl"`
  en una máquina donde el archivo aún no existe, niri puede registrar un error
  de recarga hasta que tmpfiles cree el archivo; tras el primer arranque queda
  sembrado y no vuelve a ocurrir.
- **Pausa de wallpaper por motivo**: el perfil AC/batería pausa con
  `mpvpaper-wallpaper pause power-profile`; los motivos se apilan y `resume`
  solo elimina el suyo — no usar `pause`/`resume` sin motivo para políticas
  persistentes. En batería el perfil **detiene** la capa animada
  (`mpvpaper-wallpaper stop`) para dejar visible el fondo estático de awww, y en
  AC relanza el video seteado (`~/.config/mpvpaper/current.txt`); las pausas por
  motivo quedan para la visibilidad de ventanas opacas.

---

## Cheat sheet

```bash
# Conexión
ssh loonbac@192.168.0.2
ssh loonbac@192.168.0.10

# Rebuild (desde ~/.nixos, con sudo)
cd ~/.nixos && sudo nixos-rebuild switch --flake .#$(hostname)
rebuild              # equivalente, con dry/update extra

# Verificar config de niri
niri validate --config ~/.nixos/modules/wayland/niri/config.kdl

# Flake
nix flake show
nix flake update

# Subir archivos al repo remoto
scp -i ~/.ssh/id_ed25519 <archivo> loonbac@192.168.0.2:/home/loonbac/.nixos/<ruta>
```

---

## Notas de seguridad

- SSH: solo claves (`PasswordAuthentication = false`), root no entra.
- Firewall activo por defecto; abrir puertos en `modules/networking/default.nix`.
- La contraseña de `loonbac` y el sudo se gestionan en la máquina, NO en el repo.
- `loon-launch` tiene acciones de poder (`>` → apagar/reiniciar/hibernar/...);
  al editar, no romper la ejecución vía `sh -c`.
