# Explore: hosts/ vs modules/ — diseño actual (read-only)

> Idea de ejemplo. Sin propuestas de cambio. Solo descripción del diseño vigente a 2026-09-16.

- `hosts/` es identidad + composición por máquina: `hosts/<nombre>/default.nix` solo fija `networking.hostName`, `system.stateVersion` e `imports` locales (`hardware-configuration.nix`, `platform.nix`, y extras como `power.nix` en laptop o `gaming.nix`/`streaming.nix` en PC).
- `modules/` es lógica compartida y reutilizable: agregador raíz `modules/default.nix` importa `system`, `networking`, `services`, `programs`, `wayland`, `users`; cada subárbol (ej. `services/default.nix`, `wayland/default.nix`) re-exporta sus sub-módulos.
- `flake.nix:mkHost` es el punto de composición: une `./hosts/<nombre>` + `./modules` (+ extras puntuales como `nix-flatpak`/`lanzaboote` solo en `nixos-pc`) vía `lib.nixosSystem` y `specialArgs` (zen-browser, vscode-insiders, etc.).
- Aislamiento de hardware por host: `platform.nix` y `power.nix` son exclusivos (ej. `i915`/`iHD`/`brightnessctl` solo en `loon-laptop`; AMD/NVIDIA solo en `nixos-pc`); `modules/` usa `lib.mkDefault` y `lib.optionals` sobre `hostName` para defaults sobrescribibles (ej. layout `es` vs `us`, cisco-packet-tracer solo en laptop/korosoft).
- Propiedad y límites: `hardware-configuration.nix` autogenerado no se toca; tmpfiles con regla `L+` y aserción anti-multilínea en `modules/default.nix`; fuente de verdad es el repo `~/.nixos` (symlinks en `/etc/nixos`), no edición manual en `~/.config/niri` ni similares.

## Fuentes leídas
- `flake.nix` (mkHost, nixosConfigurations loon-laptop/nixos-pc/korosoft)
- `modules/default.nix`, `modules/services/default.nix`, `modules/wayland/default.nix`, `modules/system/default.nix`
- `hosts/loon-laptop/default.nix`, `hosts/loon-laptop/platform.nix`, `hosts/nixos-pc/default.nix`
- `openspec/project.md`, `openspec/config.yaml`, `AGENTS.md`
