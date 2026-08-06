# loon-nixos — Configuración modular de NixOS (host: korosoft)

Configuración de NixOS organizada con la **misma filosofía modular** que el proyecto
[`loon-librust`](https://github.com/loonbac/loon-librust): módulos pequeños, con
responsabilidad única, componibles y declarativos. Nada de monolitos.

```
~/.nixos/
├── flake.nix                          # "Cargo.toml" del sistema
├── README.md                          # este archivo
├── hosts/                             # "binarios" — máquinas concretas
│   └── korosoft/
│       ├── default.nix                # "main.rs" — solo compone
│       └── hardware-configuration.nix # autogenerado (no tocar)
└── modules/                           # "src/core" — lógica reutilizable
    ├── default.nix                    # "mod.rs" raíz — agrega todos los módulos
    ├── system/                        # boot, zona horaria, locale, paquetes
    │   └── default.nix
    ├── networking/                    # red, firewall
    │   └── default.nix
    ├── services/                      # "core/ai/mod.rs" — compone sub-servicios
    │   ├── default.nix
    │   └── openssh/                   # cada servicio es un "crate"
    │       └── default.nix
    └── users/                         # usuarios y sus grupos
        └── default.nix
```

---

## Filosofía: loon-librust ⇄ NixOS

| loon-librust (Rust)              | NixOS (esta config)                  |
|--------------------------------|--------------------------------------|
| `Cargo.toml`                   | `flake.nix` (deps + outputs)         |
| `src/main.rs` (solo compone)   | `hosts/korosoft/default.nix`         |
| `src/core/mod.rs` (mod raíz)   | `modules/default.nix`                |
| `src/core/ai/mod.rs` (sub-mod) | `modules/services/default.nix`       |
| `src/core/ai/llm.rs`           | `modules/services/openssh/default.nix` |
| `mod foo;`                     | `imports = [ ./foo ];`               |
| `pub fn` / visibilidad        | cada módulo solo define lo suyo      |
| `cargo build`                  | `nixos-rebuild switch --flake .#korosoft` |

---

## Comandos útiles

```bash
# Aplicar cambios (desde ~/.nixos)
sudo nixos-rebuild switch --flake .#korosoft

# Probar sin aplicar (dry-run)
sudo nixos-rebuild dry-run --flake .#korosoft

# Ver qué se actualizaría / cambiaría
nix flake show
nix flake check

# Actualizar nixpkgs (el "cargo update" de NixOS)
nix flake update

# Reconstruir con un canal/commit específico
nix flake lock --update-input nixpkgs
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

3. Aplica: `sudo nixos-rebuild switch --flake .#korosoft`

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

3. Aplica: `sudo nixos-rebuild switch --flake .#korosoft`

## Cómo agregar una máquina nueva (ej. "laptop")

1. Crea `hosts/laptop/default.nix` con su `hardware-configuration.nix`.
2. Declárala en `flake.nix`:

```nix
nixosConfigurations = {
  korosoft = mkHost "korosoft" [ ];
  laptop   = mkHost "laptop" [ ];
};
```

3. Aplica desde esa máquina: `sudo nixos-rebuild switch --flake .#laptop`

---

## Notas de seguridad

- `PasswordAuthentication = false` → solo se puede entrar por **clave SSH**.
- `PermitRootLogin = "no"` → root no entra por SSH.
- El firewall está **activo** por defecto; para abrir puertos, ver
  `modules/networking/default.nix`.
- La contraseña de `loonbac` NO se guarda en este repo: se define con
  `passwd` en la máquina (o con `hashedPassword` si algún día se versiona).

## Notas sobre el host

- Hostname: `korosoft`
- Zona horaria: `America/Lima`
- Locale: `es_PE.UTF-8`, teclado `es` (X11 y consola)
- Boot: systemd-boot + UEFI
- Estado: `26.05`

## ¿Por qué no hay `configuration.nix` ya?

Porque fue **reemplazado** por la estructura de flake. El archivo `/etc/nixos/configuration.nix`
ahora es un enlace simbólico hacia `~/.nixos/hosts/korosoft/default.nix` para que
`nixos-generate-config` y herramientas antiguas sigan funcionando; pero el flake
es la fuente de verdad. La configuración vieja quedó respaldada en
`~/.nixos/configuration.nix.bak`.
