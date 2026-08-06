# loon-flakes — Configuración modular de NixOS (host: loon-laptop)

Configuración de NixOS organizada con **módulos pequeños, con
responsabilidad única, componibles y declarativos**. Nada de monolitos.

```
~/.nixos/
├── flake.nix                          # "Cargo.toml" del sistema
├── README.md                          # este archivo
├── pkgs/                              # "binarios" propios del flake
│   └── rebuild/                       # comando custom `rebuild`
│       └── default.nix
├── hosts/                             # máquinas concretas
│   └── loon-laptop/
│       ├── default.nix                # "main.rs" — solo compone
│       └── hardware-configuration.nix # autogenerado (no tocar)
└── modules/                           # "src/core" — lógica reutilizable
    ├── default.nix                    # "mod.rs" raíz — agrega todos los módulos
    ├── system/                        # boot, zona horaria, locale, paquetes
    │   └── default.nix
    ├── networking/                    # red, firewall
    │   └── default.nix
    ├── services/                      # compone sub-servicios
    │   ├── default.nix
    │   └── openssh/                   # cada servicio es un módulo propio
    │       └── default.nix
    ├── wayland/                       # compositores Wayland y greeter
    │   ├── default.nix
    │   ├── niri/                      # compositor niri (scrollable-tiling)
    │   │   └── default.nix
    │   └── dms-greeter/               # greeter DankMaterialShell (DankGreeter)
    │       └── default.nix
    └── users/                         # usuarios y sus grupos
        └── default.nix
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
| `pkgs/rebuild/`                 | binario propio del flake             |
| `imports = [ ./foo ];`          | el "mod foo;"                        |
| `rebuild`                       | el "cargo build && cargo run"        |

---

## Comando custom: `rebuild`

En lugar de escribir `sudo nixos-rebuild switch --flake .#loon-laptop` cada vez,
este flake incluye un comando propio **`rebuild`** que lo hace por ti.

```bash
rebuild          # aplica los cambios (switch) — el más usado
rebuild dry      # prueba sin aplicar (dry-run)
rebuild update   # actualiza nixpkgs (flake update) y aplica
```

- Se ejecuta desde cualquier directorio: internamente entra a `~/.nixos`.
- Pide sudo solo cuando aplica (switch/update).
- El código vive en `pkgs/rebuild/default.nix`; la instalación se hace
  desde `modules/system/default.nix`.

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

# Actualizar nixpkgs (el "cargo update" de NixOS)
nix flake update

# Probar el paquete custom sin instalarlo
nix run .#rebuild
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

## Notas de seguridad

- `PasswordAuthentication = false` → solo se puede entrar por **clave SSH**.
- `PermitRootLogin = "no"` → root no entra por SSH.
- El firewall está **activo** por defecto; para abrir puertos, ver
  `modules/networking/default.nix`.
- La contraseña de `loonbac` NO se guarda en este repo: se define con
  `passwd` en la máquina (o con `hashedPassword` si algún día se versiona).

## Notas sobre el host

- Hostname: `loon-laptop`
- Zona horaria: `America/Lima`
- Locale: `es_PE.UTF-8`, teclado `es` (X11 y consola)
- Boot: systemd-boot + UEFI
- Estado: `26.05`

## ¿Por qué no hay `configuration.nix` ya?

Porque fue **reemplazado** por la estructura de flake. El archivo `/etc/nixos/configuration.nix`
ahora es un enlace simbólico hacia `~/.nixos/hosts/loon-laptop/default.nix` para que
`nixos-generate-config` y herramientas antiguas sigan funcionando; pero el flake
es la fuente de verdad. La configuración vieja quedó respaldada en
`~/.nixos/configuration.nix.bak`.
