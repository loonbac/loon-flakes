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
├── pkgs/                      # 47 piezas propias: una carpeta = un concepto (regla 6)
│   ├── rebuild/               # comando custom `rebuild`
│   ├── loon-launch/           # launcher Rust (GTK4 + libadwaita): Cargo.toml, src/main.rs
│   ├── cargo-target-cache/    # wrapper de `cargo`: `target/` fuera del repo (desarrollo Rust)
│   ├── nixos-ssh/ ts-bypass/ laptop-power-profile/ moonlight-power/ ...
│   │                          #   operación de sistema, energía y red
│   ├── mpvpaper-wallpaper/ niri-cycle/ accent-wallpaper/ mac-plymouth/ ...
│   │                          #   wallpaper, niri y aspecto
│   ├── obs-*/ equibop-*/ veadotube-mini/ karaoke-separator/ steamidra/ ...
│   │                          #   streaming y gaming
│   └── pi*/ gentle-ai*/ engram*/ cline*/ gga/   # stack de agentes (launchers mutables)
├── hosts/                     # identidad + hardware por máquina; solo compone
│   ├── loon-laptop/           # Dell: default.nix, platform.nix (Intel), power.nix (AC/batería),
│   │                          #   extras-disk.nix (disco Proyectos sda1) y
│   │                          #   hardware-configuration.nix (autogenerado, NO tocar)
│   └── nixos-pc/              # PC: default.nix, platform.nix (NVIDIA/lanzaboote), hardware...
│                              #   y por capacidad: games-disk, projects-disk, gaming,
│                              #   streaming, sunshine, cloudflared, cross-toolchain (*.nix)
└── modules/                   # módulos compartidos por ambos hosts
    ├── default.nix            # mod raíz: registra todo + aserción de tmpfiles
    ├── system/                # boot, locale, fuentes, systemPackages
    │   ├── brightness.nix     #   opción hardware.brightness: comando screen-brightness único en ambas máquinas
    │   ├── coredump.nix       #   política de coredump compartida
    │   └── plymouth.nix       #   splash de arranque
    ├── networking/            # networkmanager, firewall
    ├── services/              # openssh, tailscale (+ts-bypass), udisks2, nixos-updates,
    │                          #   moonlight-power
    ├── programs/              # 21 módulos: fish, ghostty, rust, gtk, hyprlock, nautilus, swaync,
    │                          #   waybar, yazi, wine, virtualbox, waydroid, steam, steamidra,
    │                          #   veadotube-mini, equibop, gentle-ai, obs-studio, obs-pwvideo,
    │                          #   pi-ssh-clipboard, pear-desktop (Pear + sink virtual pear_twitch)
    ├── wayland/
    │   ├── niri/              # compositor: config.kdl + session-services.nix (unidades sesión)
    │   └── dms-greeter/       # greeter DankMaterialShell
    └── users/                 # usuario loonbac, grupos
```

Cada módulo de `modules/programs/` sigue el mismo patrón: `default.nix` con la
configuración y reglas tmpfiles que enlazan `/etc/<app>/` → `~/.config/<app>/`
(ver gotchas de tmpfiles en Lecciones aprendidas).

### Canal de PORT: remoto, con override para desarrollo local

`port` es un input **remoto** (`github:loonbac/port`), para que `nix flake update`
y por tanto `rebuild update` puedan avanzarlo. Para probar cambios que todavía no
están commiteados en `~/Proyectos/port`, se sobrescribe el input solo en esa
activación (el lock no se modifica):

```bash
sudo nixos-rebuild switch --flake .#$(hostname) \
  --override-input port git+file:///home/loonbac/Proyectos/port
```

**No apuntar el input del `flake.nix` a una copia local sucia.** Nix no puede
fijar un `dirtyRev`, entonces se niega a escribir `flake.lock` y congela *todas*
las actualizaciones del sistema: `rebuild update` deja de actualizar y el
indicador horario dice "sin cambios" aunque haya updates. Pasó del 4 al 13 de
octubre de 2026 y solo se detectó por esa señal, no por ningún error.

### `rebuild update` solo aplica si hay binarios publicados

Antes de mover el lock, `rebuild update` corre `nixos-updates gate`: actualiza los
inputs en una **copia desechable** (el `flake.lock` del repo no se toca), mide con
un dry-run cuánto habría que construir y lo separa en tres grupos:

- **lo tuyo**: los paquetes de `pkgs/`, los crates que se vendorizan para
  compilarlos y las variantes que NixOS fabrica para esta máquina
  (`_fish-completions`, `etc-*`, `sudoers`, unidades, reglas de polkit). Se
  compilan aquí siempre, porque nadie más los construye.
- **con binario**: se descargan.
- **sin binario publicado**: estos bloquean la actualización.

Si el tercer grupo queda vacío, la actualización se aplica. Si no, **no se
aplica** y el gate lista qué quedó sin binario; suele ser nixpkgs con pocas horas
de vida, que Hydra todavía no publicó, y la solución es esperar, no compilar.
Para forzar igualmente: `rebuild update force`.

La lista de "lo tuyo" se amplía sin tocar el repo: una expresión regular por
línea en `~/.config/nixos-updates-gate-allow`.

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
| Responsabilidad única | Cumple | `modules/system/` separa la configuración del sistema (`default.nix`), la lista de paquetes (`packages.nix`) y lo que hace ver al sistema (`theme.nix`) |
| Config de host en `hosts/<host>/` | Cumple | `extras-disk.nix` movido a `hosts/loon-laptop/`; ts-bypass/moonlight-power activados solo desde la laptop |
| Sin branching por hostname | Cumple | `grep -rn "networking.hostName" modules/` sin resultados; sustituido por `hardware.brightness.backend`, `services.ts-bypass.enable`, `services.moonlight-power.enable` |
| Composición explícita | Cumple | `mkHost` + `hosts/<host>/default.nix` (korosoft, host inexistente con import cruzado, fue eliminado el 2026-09-22) |
| `pkgs/` sin vertederos | Cumple | 43 paquetes con nombre por concepto; sin `utils/` ni `helpers/` |
| Sin duplicación | Parcial | `fish` unificado (se instalaba por tres vías: `systemPackages`, `programs.fish` y el shell del usuario). `ghostty`/`yazi`/`notepad-next` **no** estaban duplicados: sus módulos solo escriben configuración y referencian el binario. Sigue pendiente el patrón de tmpfiles repetido |
| Sin abstracciones muertas | Parcial | `pkgs/vision-cursor/` retirado (huérfano real: sin consumidor en el árbol vivo). Siguen los overlays exportados sin consumidor y virtualbox/waydroid/wine globales |
| Verificación proporcionada | Cumple | checks de niri/tmpfiles/tests, y `checks.${system}` del flake evalúa ambos hosts sin construirlos (`nix flake check --no-build`) |
| Cambios acotados | Práctica | se exige en cada tarea (sección 6.3 del manifiesto) |

### Deudas conocidas (orden de abordaje sugerido)

1. Activar virtualbox/waydroid/wine/obs-studio solo donde se usan (opción
   `enable`).
2. Decidir si los overlays/`nixosModules` exportados tienen consumidor externo
   real (hoy son aliases de compatibilidad; si no lo tiene, retirarlos).
3. Unificar el patrón de tmpfiles que enlaza `/etc/<app>` → `~/.config/<app>`:
   hoy se repite en cada módulo de `modules/programs/`.

> Resueltos el 2026-10-07: dividir `modules/system/default.nix` (configuración,
> paquetes y temas), unificar `fish`, retirar `pkgs/vision-cursor/`, mover los
> puertos de desarrollo a una opción del host (`loon.devPorts`) y añadir
> `checks` al flake.

---

## Flujo estándar (aplica a casi todo)

1. **Editar** el archivo correcto en `~/.nixos` (ver "Tareas comunes").
2. **`git add -A`** — OBLIGATORIO: los flakes solo ven archivos *trackeados* por
   git. Si creaste un archivo nuevo y no lo agregas, el rebuild falla con
   `Path '...' is not tracked by Git`.
3. **Aplicar**: `rebuild` (preferido; sobre SSH desacopla la activación en una unidad
   systemd, así un corte de conexión no la mata) o
   `sudo nixos-rebuild switch --flake .#<hostname>`.
4. **Entrega**: rama propia, un commit por unidad revisable, issue, PR y
   merge (ver "Entrega autónoma de un cambio"). Nunca commitear directo a
   `master`.

> **sudo no interactivo por SSH**: usar `echo <PASSWORD> | sudo -S ...`. La
> contraseña NO se guarda en el repo (es público en GitHub) — pedirla al usuario.

### Entrega autónoma de un cambio

Todo cambio de código autorizado incluye su entrega completa; no se pide
permiso entre pasos. El orden es fijo:

1. **ODD**: si la tarea es grande, `odd/tasks/<feature>.md` + espejo en Engram
   antes de la primera escritura.
2. **TDD**: prueba roja antes del arreglo cuando exista runner; si no lo hay,
   verificación funcional ejecutada y registrada (comando + salida real).
3. **Aplicar**: `rebuild` y comprobar en vivo lo que el usuario va a ver.
4. **RDD**: con `gentle-ai review mode status` en `on`, `gentle_review assess`
   → `inspect` → `start` → capturas → `acknowledge`.
5. **Rama + commits**: rama `feat/…` o `fix/…` (nunca encima de `master`), un
   commit por unidad revisable, mensaje Conventional Commit en inglés.
6. **Issue**: `gh issue create` con el defecto, la evidencia y el arreglo.
7. **PR**: `gh pr create` contra `master`, cuerpo con `Closes #<issue>`, la
   evidencia de verificación y la línea `Risk:`.
8. **Merge**: `gh pr merge <n> --squash --delete-branch` cuando los checks
   estén verdes y la revisión nativa haya cerrado; luego `git checkout master
   && git pull`.

Detenerse y preguntar solo cuando: falta una decisión de producto, hace falta
una credencial o un consentimiento nativo, un check falla sin explicación, o la
acción es destructiva o sale del alcance autorizado (force-push, reescribir
historia ajena, tocar `/boot`, cortar túneles). Que el paso siguiente sea
"obvio" no es motivo para preguntar.

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

### Entender dónde viven los artefactos de Rust (`target/`)

- **Qué hace**: el `cargo` del PATH es un wrapper (`pkgs/cargo-target-cache`,
  instalado por `modules/programs/rust`) que define `CARGO_TARGET_DIR` hacia
  `/var/cache/rust-target/<workspace>`. Un proyecto en una partición chica
  guarda solo código; los artefactos viven en el disco raíz.
- **Clave del caché**: la raíz real del workspace (`cargo locate-project`), no
  el directorio desde el que invocas: una entrada por workspace, estables para
  todos sus subdirectorios.
- **Verla**: `CARGO_TARGET_CACHE_PRINT_TARGET_DIR=1 cargo build` imprime la ruta
  sin compilar. Cada entrada tiene un `.workspace-path` con la ruta original.
- **`cargo clean`**: borra el caché de ese workspace, no el de los demás.
- **Se respeta**: un `CARGO_TARGET_DIR=... cargo ...` propio gana; fuera de un
  proyecto Cargo el wrapper no define nada; si el caché no se puede crear,
  avisa y compila como antes.
- **No añadir `rustup`**: el toolchain es el de nixpkgs y `rust-toolchain.toml`
  de los proyectos no lo cambia (ver gotchas).
- **Consecuencia**: un script que asuma `<proyecto>/target/debug` o
  `/target/release` deja de encontrar el binario; debe preguntar la ruta real
  (ver gotchas).

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

### Editar AnyDesk (escritorio remoto)

- **Módulo**: `modules/programs/anydesk/default.nix`. nixpkgs no trae módulo
  NixOS para AnyDesk: el paquete deja la unidad en `$out/lib/systemd/system`,
  y el módulo la importa con `systemd.packages` + `wantedBy` en vez de
  reescribirla.
- **Dos piezas**: la app (`anydesk`, GUI) y `anydesk.service` (`--service`,
  User=root). El servicio es lo que habilita conexiones entrantes y la pantalla
  de login; sin él solo funciona con la GUI abierta.
- **PATH del servicio**: la unidad ejecuta el binario del store sin el wrapper
  del paquete, así que su PATH es el mínimo de systemd y `ip`, `lsblk` y
  `domainname` fallaban en el journal. Se corrige con
  `systemd.services.anydesk.path = [ "/run/current-system/sw" ]`.
- **Límite real en Wayland**: el wrapper fija `GDK_BACKEND=x11`, así que
  AnyDesk corre sobre XWayland (niri lo aporta con `xwayland-satellite`). Puede
  ver y controlar ventanas X11, pero **no** ventanas Wayland nativas ni la
  sesión de niri. Para controlar todo el escritorio hace falta
  `org.freedesktop.portal.RemoteDesktop` (libei), que AnyDesk todavía no
  implementa; no se resuelve desde Nix. Alternativas que sí lo cubren:
  `rustdesk` (nixpkgs, soporte Wayland vía portal) o
  `krdp`/`wayvnc` (VNC con `wlr-screencopy` en wlroots; niri soporta
  `wlr-screencopy` y `wlr-virtual-pointer`).
- **Verificar**: `systemctl status anydesk`, `anydesk --get-id` y que el
  journal no repita los errores de `ip`/`lsblk`.
- **Aviso cosmético conocido**: el journal muestra `domainname: invalid option
  -- 'A'`. AnyDesk pide el FQDN con una opción que el applet `domainname` de
  NixOS (parte de `hostname`) no acepta; cae al nombre corto y no afecta al
  funcionamiento. No se parchea el binario por esto.

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

### MCP de Pi (built-in) y codemode

- **Dueño**: `pkgs/gentle-ai-bootstrap/default.nix`. Pi ≥ 0.99 trae MCP propio, así que
  `pi-mcp-adapter` **no se declara ni se instala**: gentle-ai ≥ 4.2.0 lo retira, y mientras
  estuvo instalado apagaba el MCP interno. Volver a declararlo reproduce el vaivén (Nix lo
  instala en el rebuild, gentle-ai lo retira en el siguiente sync).
- **MCP**: `piSettings.extensions = [ ]` deja que Pi cargue sus defaults, `builtin:mcp`
  incluido. Con la exposición por defecto (`codemode`) las tools del servidor no se declaran
  al modelo: las llama la tool `codemode` desde un script.
- **`-builtin:codemode` es del usuario, no del repo**: gentle-pi sustituye el codemode
  builtin por su renderer compacto y, si el usuario acepta el prompt una vez, escribe esa
  entrada para silenciar el aviso de Pi. El repo la deja en paz a propósito:
  `retiredPiExtensions` solo retira `-builtin:mcp`, porque filtrar la de codemode la revierte
  en cada activación y gentle-pi vuelve a preguntar. Codemode funciona igual (lo aporta
  gentle-pi).
- **Forzar codemode (`pkgs/pi-codemode-forcer`)**: el default de Pi es `codemode.mode: "on"`,
  que deja los tools nativos declarados y por tanto vuelve opcional agrupar. Medido en este
  repo: 40.968 llamadas a `bash` en 30 días contra **169 a `codemode`**, que además solo se
  usaba como puerta a las MCP tools. La extensión cierra esa brecha con dos reglas decididas
  en el hook `tool_call`, antes de ejecutar, y ambas son chequeos de nombre sobre
  `parentToolCallId` (campo que Pi rellena cuando la llamada viene de un script):
  - **Ejecución nativa bloqueada**: `bash`, `bash_background`, `read`, `edit`, `write`,
    `grep`, `find`, `ls` llamados desde el modelo se bloquean y el motivo trae el script
    listo para pegar con `tools.<nombre>({...})`. Nada se ejecutó, así que no hay trabajo
    que rehacer: solo se reemite la misma operación dentro de un script.
  - **Host dentro de un script bloqueado**: `ask_user_choice`, `ask_user_question`,
    `request_secret`, `gentle_review*`, `subagent_run` y `subagent_continue` no pueden
    correr en el sandbox de QuickJS porque necesitan la UI o un relé del host. Si un script
    los invoca, se bloquean; lo que el script ya ejecutó antes queda hecho.
  - **Escape**: `PI_CODEMODE_FORCE=0` desactiva la exigencia en una invocación. Cada bloqueo
    se anota en `~/.pi/agent/codemode-forcer.log` (0600) para poder medir el efecto: el
    objetivo es pasar de 1,09 comandos por turno a más de 2,5.
  - Verificado: `bash` nativo bloqueado y reintentado por codemode; `ask_user_question`
    bloqueado con `fromScript: true`. La extensión se enlaza desde `piSettings.extensions`
    y `mergeSettings` une listas, así que no pisa el `-builtin:codemode` del usuario.
  - **La lista `HOST_ONLY` no se escribe de memoria**: se saca de `getAllTools()` (75 tools
    configurados, 72 activos en esta sesión). Fuera de la lista quedan a propósito las
    lecturas puras (`get_goal`, `subagent_status`, `subagent_result`, `subagent_list_*`,
    `job_list`, `orchestrator_list`): bloquearlas costaría un turno sin ganar nada. Solo
    `ask_user_question` está verificado empíricamente; el resto se clasificó por contrato.
  - **Gotcha del merge de extensiones**: una extensión declarada como archivo cambia de
    store path en cada activación, y la unión conservaba el anterior para siempre, así que
    la extensión se cargaba dos veces y el JSON crecía. `mergeSettings` ahora compara por
    nombre **quitando el prefijo `<hash32>-` del store**: comparar por basename no sirve
    porque el basename incluye el hash.
- **Ficheros**: el único config de usuario que Pi lee es `~/.pi/agent/mcp.json` (symlink a
  `mcpConfig`). `mcp-adapter.json`, `mcp-cache.json` y `mcp-project-approvals.json` eran del
  adaptador: la activación los mueve a `backups/nix-gentle-ai/<fecha>/pi-mcp-adapter/`.
- **`engram` no se declara** en `mcpServers`: la extensión gentle-engram registra los `mem_*`
  nativos por HTTP y su README pide quitar esa clave para evitar doble escritura. Queda `lida`.
- **Configs de proyecto**: Pi lee `.pi/mcp.json`, no `.mcp.json` (eso lo leía el adaptador).
  Un `.mcp.json` existente se **copia** a `.pi/mcp.json` para no romper otros clientes.
- **Retirar entradas ya escritas**: `mergeSettings` solo une listas, así que una entrada que
  deja de declararse se filtra con `retiredPiExtensions` (o `retiredPiPackageNames` para
  paquetes). Sin ese filtro sobrevive en `settings.json` y el built-in sigue apagado. Retirar
  es para entradas que el repo declaró y ya no quiere, no para las que el usuario eligió.
- **Verificar**: `pi mcp list` (conecta y muestra exposure/tools) y que `settings.json` no
  conserve `-builtin:mcp`; `-builtin:codemode` sí puede estar ahí.
- **MCP `google-flow`**: automatiza `flow.google.com` desde un Chrome ya autenticado (33 tools
  `flow_*`). Nix solo declara el server; los bytes mutables viven en el home:
  `~/.local/share/loon-pi-mcp/google-flow` (clone + `npm install` + `npm run build`) y el
  wrapper `run-google-flow-mcp`. Actualizar: `git pull --rebase && npm install && npm run build`
  (rama `development`; con `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` al instalar: el server solo
  se conecta por CDP).
  Config editable: `google-flow/config/flow.config.json` (`expectedAccount`, perfil y puerto).
  Lanzar el navegador: `npm run start-browser` desde esa carpeta, o `flow_connect` si ya corre.
- **Chrome 155 rechaza CDP en el directorio por defecto**: con
  `DevTools remote debugging requires a non-default data directory` el flag
  `--remote-debugging-port` se ignora en silencio (sin `DevToolsActivePort` y sin puerto).
  Por eso el MCP usa `~/.config/google-chrome-flow` (perfil propio, copia del de siempre) y
  `cdpPort: 9333`, no el 9222 que ocupan los chromium de pruebas. Si se pierde el login, se
  copia el perfil autenticado con Chrome cerrado:
  `cp -a ~/.config/google-chrome/{Default,"Local State"} ~/.config/google-chrome-flow/`.
  Verificar la cuenta con `flow_account_check` (`verified: true`, `method: ui-chip`).
- **`google-flow`: rama `development`, no `master`** (estado 2026-10-21). El clone corre
  `development` (7e86e05) porque `master` todavía tiene la sumisión remota deshabilitada
  (`Gate A`, solo `local-fixture`). `development` añade `executionMode: live-browser`
  (`src/domain/live-submission.js`), `freeCharacterImages`, `flow_rename_image`, presupuesto
  de créditos por proyecto (`projectCreditCap`, 50 por defecto) y arreglos de subida de
  referencias/menciones. Verificado en vivo:
  - Imagen: `flow_generate_image {auto_confirm: true}` → `executionMode: live-browser`,
    `quote.total: 0` (Nano Banana 2.1) y clic real. Una sola imagen con `quantity: 1`.
  - Subida + mención: `reference_images: ["/ruta/local.png"]` sube el archivo (aparece en
    `flow_list_mention_options`), pero **la sumisión en vivo con `reference_images` se
    rechaza** (`POLICY_DENIED: local-reference-identity-unavailable`): una ruta local no
    identifica el asset remoto. El camino bueno es subir una vez y luego referenciar por
    nombre con `ingredients: ["archivo.png"]`; el binding resuelve el `assetId` del chip
    (`{"assetId": "...", "title": "...", "role": "ingredient"}`) y el clic procede.
  - Video: `flow_generate_video {model: "Omni 1.1 Flash", duration: "8s", quality: "360p",
    ingredients: ["archivo.png"], confirm_generate: true, max_credits: 6}` → cotizó
    **6 créditos** en el panel y generó. Veo (Fast/Lite/Quality) ~20.
  - La cola de trabajos es **en memoria**: `flow_generate_video` (prepare) y
    `flow_generate_confirm` deben ocurrir en el mismo proceso MCP; reiniciar el server pierde
    el `jobId`. Lo mismo vale para el ledger de créditos, que persiste en
    `project-credit-budgets/` (estado de runtime, ignorado por git).
  - `flow_download_latest` sin `assetId` sigue ambiguo (tiles duplicados sin identidad); con
    `assetId` funciona. Hay un PR abierto (#4) que baja el asset por red cuando CDP no emite
    evento de descarga.
- **`google-flow`: dos parches locales commiteados en `development`** (`e0ba62c`, `38941a3`).
  **Idioma**: manda el de la cuenta (`es-419`) y los selectores del upstream son ingleses;
  ni `intl.accept_languages` ni la cookie `PREF=hl=en` lo cambian, `?hl=en` sí. `src/utils/flow-locale.js`
  (`withFlowLocale`) lo fija en cada navegación. **Chip de configuración**: el
  `Settings trigger` viejo puede quedar oculto mientras el visible es icon-only con
  `aria-label="Settings"`; `openBarSettings` ahora lo acepta antes de la heurística de texto.
  **Modo agente**: si está activo no hay chips de modelo/ratio (solo el panel "Agent
  settings" con defaults por proyecto); `development` lo apaga y verifica en cada corrida de
  imagen, pero conviene dejarlo apagado en el composer (pill `Agent`).
  Al hacer `git pull` sobre `development`, resolver estos dos commits locales con rebase.
- **Provider `inception` (Mercury 3)**: declarado en `piModelProviders` de
  `pkgs/gentle-ai-bootstrap/default.nix`, no en `models.json` a mano, para que se re-inyecte en
  cada activación (`Object.assign`, aditivo: no borra providers del usuario). Es un endpoint
  OpenAI-compatible (`https://api.inceptionlabs.ai/v1`, `api: openai-completions`), así que
  **no usa el puente LiteLLM** que la doc de Inception propone para Claude Code: Pi habla el
  protocolo directo. Detalles: `mercury-3`, 1M de contexto, 131 072 de salida, `reasoning: true`
  con `thinkingLevelMap` (`off→instant`, `low→low`, `medium→medium`, `high→high`, `xhigh/max`
  sin soporte) y `compat` con `maxTokensField: max_completion_tokens` +
  `supportsDeveloperRole: false`.
  - **La API key no está en el repo ni en el store**: `apiKey` se resuelve con
    `!cat /home/loonbac/.config/inception/api-key` (archivo 0600) en tiempo de request. Nunca
    escribir la clave en `models.json` versionado, en Nix, ni en `AGENTS.md`; el repo es público.
  - Verificado: `GET /v1/models` lista `mercury-2, mercury-2.5, mercury-3, mercury-decide`;
    `pi -p --provider inception --model mercury-3` responde exacto y usa tools (leyó
    `/etc/hostname`); el provider sobrevive al rebuild.
  - Rotar la key = editar ese único archivo; no hay que rebuildear.
- **Provider `alibaba-token-plan` (plan Starter/Essential comprado)**: declarado en
  `piModelProviders` de `pkgs/gentle-ai-bootstrap/default.nix`. Endpoint OpenAI-compatible
  `https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` (región Singapur,
  única disponible). La clave vive en `~/.config/alibaba-token-plan/api-key` (0600) y **empieza
  por `sk-sp-`**: no es intercambiable con la de pago por uso (`sk-`) ni con Coding Plan, y el
  endpoint debe ser el par correcto — usar la clave genérica factura aparte del plan y no se
  puede descontar. Modelos declarados: `deepseek-v4.1-flash-1017`, `deepseek-v4.1-flash`,
  `glm-5.3`, `qwen3.8-max` (todos 1M contexto). `compat.thinkingFormat = "qwen"` porque el
  gateway usa `enable_thinking` (convención DashScope); acepta además `thinking.type` y
  `reasoning_effort` (`low`/`high`/`max`). Máx salida 393 216 en DeepSeek, 131 072 en GLM/Qwen.
  - **Descuento nocturno 50 %** para `deepseek-v4.1-flash*`, `deepseek-v4-pro-0813` y
    `deepseek-v4-flash-0731` entre 22:00 y 08:00 UTC+8, que en Perú (UTC-5) es **09:00–19:00**:
    toda la jornada laboral paga la mitad de créditos.
  - Verificado: `pi -p --provider alibaba-token-plan --model deepseek-v4.1-flash-1017` responde
    exacto y usa tools; streaming SSE con `stream_options.include_usage` funciona.
  - Límite real del plan: no es la cuota de créditos sino la **concurrencia** (Essential 2–3
    agentes). Si se agotan los créditos, las llamadas se bloquean y **no** pasan a pago por uso.
- **Compactación de Pi: el ajuste que más ahorra** (`~/.pi/agent/settings.json`, no en Nix).
  Por defecto `reserveTokens = 16384`, así que con un modelo de 1M de contexto Pi compacta recién
  a **983 616 tokens**. Los logs del 2026-10 mostraron compactaciones con `tokensBefore` mediano de
  469 418 y p90 de 770 073: arrastrar ese contexto costaba el 62 % del gasto en *input miss*.
  Configuración aplicada: `compaction.reserveTokens = 16384` global (los modelos pequeños, 65k y
  262k, no toleran un reserve alto) y **`modelOverrides` con `reserveTokens: 850000`** para cada
  modelo de 1M de contexto (`alibaba-token-plan/*`, `opencode-go/deepseek-v4.1-flash`,
  `workbuddy/*`, `commandcode/*`, `intern-ai/*`, `river*/*`). Eso compacta a ~150k. Ahorro
  proyectado: 55 % del coste.
- **Compactación de Pi: el ajuste que más ahorra** (`~/.pi/agent/settings.json`, no en Nix).
  Por defecto `reserveTokens = 16384`, así que con un modelo de 1M de contexto Pi compacta recién
  a **983 616 tokens**. Los logs del 2026-10 mostraron compactaciones con `tokensBefore` mediano de
  469 418 y p90 de 770 073: arrastrar ese contexto costaba el 62 % del gasto en *input miss*.
  Configuración aplicada: `compaction.reserveTokens = 16384` global (los modelos pequeños, 65k y
  262k, no toleran un reserve alto) y **`modelOverrides` que fijan un umbral de 250 000 tokens**
  para cada modelo del catálogo. Ahorro proyectado: 55 % del coste.
  - **El umbral se calcula, no se escribe a mano**: `pi-compaction-threshold`
    (`pkgs/pi-compaction-threshold`, en PATH y como `runtimeInputs` de
    `gentle-ai-bootstrap`) lee `pi --list-models` y deriva un `reserveTokens` igual a
    `contextWindow − 250000` (piso `65536`) para cada modelo que supere el umbral. Escribe con
    merge **aditivo**: nunca borra una entrada, así un catálogo parcial (auth caída, proveedor sin
    red) no destruye la configuración. Corre en cada activación, después de `pi install`, que
    también reescribe `settings.json`. Verificar: `pi-compaction-threshold` (dry run) y `--apply`
    para escribir.
  - **Por qué 250 000 y no 150 000**: el modelo de coste con las tasas reales (input
    `$0,0601/1M`, output `$0,4219/1M`, cacheRead `$0,0032/1M`, 44 503 llamadas, crecimiento
    13 382 tok/llamada, piso post-compactación 24 100 tok) da un óptimo entre 190k y 290k, estable
    en 6 escenarios de sensibilidad. A 250k el gasto es `$67,40/mes` con **2 636 compactaciones**;
    a 150k es `$69,87/mes` con **4 730** (una cada 9,4 llamadas, "a cada rato"). 250k compacta 44 %
    menos al mismo coste. 636k sube a `$87,26` y 983 616 a `$110,39`.
  - **No hay comodines**: el schema es `TRecord<"^.*$", …>` con claves exactas `provider/model`,
    así que la enumeración es obligatoria. Los 36 overrides manuales previos cubrían solo 58,2 % de
    los tokens; el catálogo vivo cubre ahora **99,95 %** (155 entradas para 200 modelos).
  - **No conviene tocar el caché**: en los logs el *cache read* era 15,45 B tokens (24 % del gasto)
    mientras el *input miss* eran 0,805 B (62 %). El caché es el aliado; lo caro es el token nuevo.
  - Medir el consumo real: `~/.local/bin/pi-usage` (script propio, sin dependencias). Lee los
    `.jsonl` de `~/.pi/agent/sessions/**`, que guardan `usage` por respuesta (`input`, `output`,
    `cacheRead`, `cacheWrite`, `totalTokens`), y separa tokens **nuevos** de **caché**. Opciones:
    `--today`, `--days N`, `--models`. Da el gasto exacto sin depender del panel del proveedor y
    revela la señal que importa: el ratio caché/nuevo y el reparto de niveles de *thinking*.
  - **Al añadir un modelo** ya no hay paso manual: si el modelo aparece en `pi --list-models` con
    `contextWindow` suficiente, la siguiente activación le pone el override. Peor que un umbral
    tarde es un modelo **sin** `contextWindow` en `models.json`: Pi no sabe cuándo compactar. Se
    corrigieron los 7 de `infronai` consultando `/v1/models` del propio gateway.
  - **`defaultThinkingLevel` = `high`** por decisión del usuario (2026-10-23): hace sobre todo
    diseño y arquitectura, y ahí el razonamiento de calidad compensa. El coste se controla con la
    compactación, no bajando el nivel. En los logs el 82,9 % de las llamadas ya corrían en
    `high`, y el razonamiento se factura como *output* (el token más caro): si el gasto se dispara,
    el primer ajuste es bajar a `medium` antes que tocar la compactación.
  - **Ojo al reescribir `settings.json`**: la sesión viva de Pi lo reescribe desde memoria y puede
    perder entradas añadidas a mano (ocurrió con 15 overrides). Aplicar, comprobar, y cerrar sesión
    antes de editar a mano si hace falta. Verificado que persiste tras `pi -p`.
- **MCP `dataimpulse`** (proxy residencial para páginas que bloquean o cambian por región).
  Server propio en `~/mcp/dataimpulse` (Node ESM, stdio, `@modelcontextprotocol/sdk` + `undici`
  + `zod`): `fetch_page(url, country?, city?, session?, raw?)` y
  `check_exit_ip(country?, session?)`. Nix declara solo el wrapper
  `~/mcp/dataimpulse/run.sh` en `mcpConfig`; las credenciales viven en
  `~/mcp/dataimpulse/.env` (0600) y el wrapper las exporta **solo a ese proceso hijo**.
  Regla dura: nunca `HTTP_PROXY`/`HTTPS_PROXY` globales (shell, config de agente, archivo):
  ruteaban todo el tráfico de API por una IP residencial y quemaban el plan.
  - DataImpulse: `gw.dataimpulse.com`, rotating HTTP 823 (SOCKS5 824), sticky 10000-20000;
    targeting en el username: `login__cr.ar`, `;city.madrid`, `;sessid.etiqueta`
    (`sessid` fija la IP 30 min). `city` cobra doble tarifa: usar solo país por defecto.
  - Errores mapeados a pista accionable: 407 `TRAFFIC_EXHAUSTED` (sin gigas),
    407 `THREADS_EXHAUSTED` (>2000 conexiones), 503 `NO_RAY` (targeting de ciudad demasiado
    fino: sacar `city`), 403 (el sitio bloqueó igual: cambiar país o `session`).
  - Verificado 2026-10-22: tres salidas distintas (`sin país` 187.95.17.122, `ar`
    207.191.167.135, `es` 154.60.231.34), `api.country.is` devuelve AR/ES acorde, dos
    llamadas con el mismo `sessid` repiten IP, y `pi mcp list` reporta `dataimpulse:
    connected, 2 tools`. Actualizar dependencias: `cd ~/mcp/dataimpulse && npm install`.
---

## Lecciones aprendidas (gotchas)

- **`nix flake update` a secas está prohibido aquí**: mueve `nixpkgs` y con él
  todos los store paths, lo que deja inservible la caché binaria propia
  (`loon-flakes`) incluso para el cierre del sistema. Para subir un input
  concreto hay que nombrarlo: `nix flake update port`. La única vía que puede
  mover `nixpkgs` es `rebuild update`, que pasa antes por el gate de binarios
  publicados.

- **Un movimiento de `nixpkgs` y el bump del lock de `port` viajan en el mismo
  PR**: ambos cambian store paths, así que la caché binaria queda desalineada
  hasta que corra CI con el lock nuevo. Juntos se paga un solo ciclo de runner
  y la caché queda coherente de una vez; separados, el run intermedio publica
  paths que ya nadie va a usar.

- **Rutas `target/` fijas en proyectos con el caché de Rust**: con el wrapper de
  `cargo` los artefactos ya no están en `<proyecto>/target`. Scripts revisados
  que lo asumían: `shirley-show/scripts/verify-responsive.sh` y su copia en
  `shirley-show-responsive/`, `lawa/build.sh` y `port/scripts/package.sh` (este
  último sí tiene fallback). Patrón correcto:
  `"${CARGO_TARGET_DIR:-target}/release/<bin>"` o preguntar la ruta con
  `cargo metadata --format-version 1 | jq -r .target_directory`. Los Dockerfiles
  no se ven afectados: construyen con su propio filesystem y entorno.
- **`rust-toolchain.toml` es inerte sin rustup**: los proyectos piden
  `channel = "1.95.0"` y el cargo de nixpkgs es 1.95.0, así que hoy coinciden.
  Si un proyecto pide otra versión, cargo no la respeta: el toolchain se cambia
  en `modules/programs/rust`, o se decide instalar rustup como decisión de
  política (no como ajuste suelto).
- **`imports`: el orden importa, y es al revés.** `lib/modules.nix` fusiona las
  definiciones en orden **inverso** al de la lista `imports`, así que reordenarla
  o dividir un módulo en varios cambia el orden final de listas como
  `environment.systemPackages` y con él el hash de `system-path`, aunque el
  conjunto de paquetes sea el mismo. Al dividir un módulo, comprobar que el
  `drvPath` del toplevel de ambos hosts no cambie; en `modules/system/default.nix`
  los imports quedan en el orden que reproduce la fusión histórica y un
  comentario lo explica.
- **Paquetes declarados por varias vías**: `programs.fish.enable` y
  `users.users.<u>.shell` ya instalan el paquete, así que repetirlo en
  `environment.systemPackages` es una tercera declaración (y tocar esa lista
  mueve el hash de `system.path`, que usa la lista cruda).
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
- **`switch` en vivo vs `boot`**: un `switch` en vivo es la forma normal de
  aplicar cambios sin reiniciar; lo que hay que evitar es que la activación
  dependa de la conexión del cliente (`systemd-run --pipe`), porque si el
  cliente muere (p. ej. por un timeout de SSH) systemd aborta la activación a
  mitad y puede dejar servicios detenidos sin re-arrancar (incidente del
  2026-09-22: NetworkManager quedó detenido). Por eso, sobre SSH se debe usar
  `rebuild` (se desacopla solo en una unidad systemd transitoria y permite
  seguirla con `sudo journalctl -u <unidad> -f`), o lanzar la activación
  desacoplada a mano. Avisar siempre al usuario de que la activación re-servicia
  unidades (la sesión, la barra o el wallpaper pueden parpadear unos segundos).
  `rebuild update` sigue usando `boot` por el motivo documentado
  (greetd/PAM/systemd/drivers).
- **Primera activación de `monitor.kdl`**: cuando se habilita `include "monitor.kdl"`
  en una máquina donde el archivo aún no existe, niri puede registrar un error
  de recarga hasta que tmpfiles cree el archivo; tras el primer arranque queda
  sembrado y no vuelve a ocurrir.
- **Pausa de wallpaper por motivo**: el perfil AC/batería pausa con
  `mpvpaper-wallpaper pause power-profile` y el watcher de visibilidad con
  `opaque-window`; los motivos se apilan. `resume MOTIVO` retira solo el suyo
  (es lo que usan esos actores); `resume` sin motivo los retira todos y es la
  orden explícita del usuario. Toda política persistente debe nombrar su
  motivo y usar `resume MOTIVO`, nunca `pause`/`resume` sin argumento.
- **Ventanas transparentes y `opaque-window`**: `pkgs/niri-wallpaper-visibility`
  pausa el fondo cuando la ventana activa de un workspace visible es opaca. La
  lista `TRANSPARENT_APP_IDS` del watcher debe coincidir con lo que de verdad
  deja ver el fondo: ghostty (`opacity 0.8` + `xray` en `config.kdl`) y PORT
  (`opacity 0.85` en su `config.md`). Si la lista se queda corta, el fondo se
  congela detrás de una terminal transparente; si sobra una app opaca, se
  decodifica video que nadie ve.

---

## Cheat sheet

```bash
# Conexión
ssh loonbac@192.168.0.2
ssh loonbac@192.168.0.10

# Rebuild (desde ~/.nixos)
rebuild              # switch: por SSH se desacopla en una unidad systemd independiente
                     #   (seguir con: sudo journalctl -u loon-rebuild-<epoch> -f)
cd ~/.nixos && sudo nixos-rebuild switch --flake .#$(hostname)   # equivalente manual

# Verificar config de niri
niri validate --config ~/.nixos/modules/wayland/niri/config.kdl

# Caché de artefactos de Rust (por qué un proyecto ya no tiene target/)
CARGO_TARGET_CACHE_PRINT_TARGET_DIR=1 cargo build   # ruta del caché del workspace
CARGO_TARGET_DIR="./target" cargo build             # compilar en el proyecto
sudo du -sh /var/cache/rust-target/*                # qué ocupa cada workspace

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
- El token del túnel de Cloudflare (`hosts/nixos-pc/cloudflared.nix`) vive en
  `/var/lib/cloudflared/token` (0400 root) y **no** en el repo: el repositorio es público. Se
  aprovisiona a mano en cada máquina y se rota desde el panel de Zero Trust; el módulo no
  declara ni el archivo ni su contenido (acabaría en el store).
- **El túnel es una vía de acceso remoto** (`bypass.loonbac-dev.moe` → `ssh://localhost:22`):
  hay gente que entra a esta máquina por ahí. No detengas ni reinicies `cloudflared-tunnel`
  sin confirmarlo primero: un `stop` corta la sesión de quien lo esté usando. Lo mismo aplica
  a `ts-bypass`/Tailscale. Si hay que cambiarlo, avisa y elige el momento.
- **Nunca pases el token en la línea de comandos** (`--token <valor>`): acaba en el journal
  persistente y en la unidad transitoria. Usa siempre `--token-file`, y para aprovisionarlo
  `read -rsp` + `tee` (nunca `systemd-run ... --token`).
- `loon-launch` tiene acciones de poder (`>` → apagar/reiniciar/hibernar/...);
  al editar, no romper la ejecución vía `sh -c`.
