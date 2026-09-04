# AGENTS.md — loon-flakes (NixOS de loon-laptop)

Guía para agentes/asesores que trabajen sobre la configuración de NixOS de la
máquina **loon-laptop**. Léelo completo antes de tocar nada: contiene el
contexto, los flujos exactos y las trampas aprendidas en el camino.

---

## Contexto general

- **Máquina**: NixOS 26.05, hostname `loon-laptop` (antes se llamaba `korosoft`).
- **Acceso SSH**: `ssh loonbac@192.168.0.2` con la clave `~/.ssh/id_ed25519`
  (la máquina local ya tiene la clave en `authorized_keys`, **sin contraseña**).
  La autenticación por contraseña por SSH está **desactivada** (`PasswordAuthentication = false`).
- **Repositorio de config**: `~/.nixos` en la máquina remota, es un repo git
  cuyo remote es `https://github.com/loonbac/loon-flakes.git` (rama `master`).
- **`/etc/nixos`** son symlinks a `~/.nixos/hosts/loon-laptop/` — la fuente de
  verdad es el repo, no `/etc/nixos`.
- **`rebuild`**: comando custom del sistema (definido en `pkgs/rebuild/`) que
  corre `sudo nixos-rebuild switch --flake .#loon-laptop` desde `~/.nixos`.
  También acepta `rebuild dry` (dry-run) y `rebuild update` (flake update + switch).

## Estructura del repo (`~/.nixos`)

```
~/.nixos/
├── flake.nix                  # inputs (nixpkgs 26.05), mkHost, packages
├── flake.lock                 # lockfile (versionar, no tocar a mano)
├── README.md                  # doc de usuario
├── AGENTS.md                  # este archivo
├── pkgs/
│   ├── rebuild/               # comando custom `rebuild`
│   └── loon-launch/           # launcher Rust (GTK4 + libadwaita)
│       ├── Cargo.toml
│       ├── Cargo.lock
│       ├── default.nix        # buildRustPackage
│       └── src/main.rs
├── hosts/
│   └── loon-laptop/
│       ├── default.nix        # identidad del host (solo compone)
│       ├── power.nix          # perfil AC/batería exclusivo del Dell
│       └── hardware-configuration.nix  # autogenerado, NO tocar
└── modules/
    ├── default.nix            # mod raíz: registra todos los módulos
    ├── system/                # boot, timezone, locale, systemPackages
    ├── networking/            # networkmanager, firewall
    ├── services/
    │   ├── default.nix        # registra sub-servicios
    │   └── openssh/           # servicio SSH (solo claves)
    ├── wayland/
    │   ├── default.nix        # registra compositores/greeters
    │   ├── niri/              # compositor niri + config.kdl gestionado
    │   └── dms-greeter/       # greeter DankMaterialShell
    └── users/                 # usuario loonbac, grupos

`modules/programs/` contiene además los módulos `fish/`, `ghostty/`,
`waybar/` y `equibop/` (ver "Equibop + Tailscale" en Lecciones aprendidas).
```

## Flujo estándar (aplica a casi todo)

1. **Editar** el archivo correcto en `~/.nixos` (ver "Tareas comunes").
2. **`git add -A`** — OBLIGATORIO: los flakes solo ven archivos *trackeados* por
   git. Si creaste un archivo nuevo y no lo agregas, el rebuild falla con
   `Path '...' is not tracked by Git`.
3. **Aplicar**: `sudo nixos-rebuild switch --flake .#loon-laptop` (o `rebuild`).
4. **Commit + push**:
   ```bash
   git add -A
   git -c user.name="loonbac" -c user.email="loonbac@users.noreply.github.com" commit -m "feat: ..."
   git push origin master
   ```

> **sudo no interactivo por SSH**: usar `echo <PASSWORD> | sudo -S ...`. La
> contraseña NO se guarda en el repo (es público en GitHub) — pedirla al usuario.

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

### Editar la config de niri

- **Archivo**: `modules/wayland/niri/config.kdl` — gestionado por NixOS:
  se instala en `/etc/niri/config.kdl` y `~/.config/niri/config.kdl` es un
  symlink (tmpfiles). **No editar `~/.config/niri` a mano**; editar el repo.
- **Validar**: `niri validate --config <ruta>` (hay `niri` instalado también en
  la máquina local).
- **Binds actuales**: `Super+Return` → ghostty, `Super+Space` → loon-launch.
  En XKB la tecla Enter se llama `Return`. `Super+Space` existe solo si se
  define; niri no tiene binds por defecto.

### Editar el perfil AC/batería de loon-laptop

- **Activación exclusiva**: `hosts/loon-laptop/power.nix`, importado solo por
  `hosts/loon-laptop/default.nix`. Nunca registrarlo en `modules/` ni en el
  agregador global.
- **Hardware**: `pkgs/laptop-power-profile/laptop-power-profile.sh`.
- **Sesión niri/mpvpaper**:
  `pkgs/laptop-power-profile/laptop-power-profile-session.sh`.
- **Wallpaper IPC**: `mpvpaper-wallpaper pause|resume|status`; el socket vive
  en `$XDG_RUNTIME_DIR/mpvpaper-wallpaper/mpv.sock`.
- **Aislamiento**: comprobar siempre ambos hosts y verificar que korosoft no
  tenga `laptop-power-profile.service` ni
  `laptop-power-profile-session.service`.

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

---

## Lecciones aprendidas (gotchas)

- **Flake + git**: archivos nuevos sin `git add` → error "not tracked by Git".
- **"Git tree is dirty"**: aviso normal cuando hay cambios sin commitear; el
  rebuild funciona igual. Desaparece al commitear.
- **tmpfiles**: `L+` NO reemplaza un archivo regular existente (solo actúa si
  no existe o ya es symlink). Usar **ruta absoluta** (`/home/loonbac/...`),
  systemd no expande `~` en tmpfiles.
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

---

## Cheat sheet

```bash
# Conexión
ssh loonbac@192.168.0.2

# Rebuild (desde ~/.nixos, con sudo)
cd ~/.nixos && sudo nixos-rebuild switch --flake .#loon-laptop
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
