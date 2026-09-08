# Apply Progress: Extract SteaMidra NixOS Module

**Change ID:** `extract-steamidra-nixos-module`
**Status:** In Progress / Completed Implementation
**Work Unit:** `public-steamidra-module`
**Attempt Token:** `sha256:0cad2313fa58afa71aa34911c7c0e74864cbe2c7a20455cc4bc8e35bb04f2f34`

## Execution Summary

Implemented the standalone opt-in SteaMidra NixOS module, exported public flake package/module/overlay attributes, eliminated internal `specialArgs.steamidra` passing in `mkHost`, and migrated `nixos-pc` to consume `programs.steamidra.enable = true;`.

### Source Files Changed

1. `modules/programs/steamidra/default.nix` (new):
   - Defines `programs.steamidra.enable` using `lib.mkEnableOption "SteaMidra"`.
   - Defines `programs.steamidra.package` using `lib.mkOption` defaulting to `pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { })` with literal expression default text `"pkgs.steamidra"`.
   - Conditionally configures assertions for `pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64` with message `"programs.steamidra is only supported on x86_64-linux."`.
   - Appends `cfg.package` to `environment.systemPackages` when enabled.
   - Preserves complete absence of definitions for graphics, display servers, XWayland, users, groups, tmpfiles, or network policies.

2. `modules/programs/default.nix`:
   - Registers `./steamidra` in `imports`.

3. `flake.nix`:
   - Added shared bindings `steamidraPackage = pkgs.callPackage ./pkgs/steamidra { };`, `steamidraOverlay = final: _prev: { steamidra = final.callPackage ./pkgs/steamidra { }; };`, and `steamidraModule = ./modules/programs/steamidra;`.
   - Reused `steamidraPackage` for `packages.${system}.steamidra`.
   - Exported `overlays.steamidra = steamidraOverlay;` and `overlays.default = steamidraOverlay;`.
   - Exported `nixosModules.steamidra = steamidraModule;` and `nixosModules.default = steamidraModule;`.
   - Removed `steamidra = pkgs.callPackage ./pkgs/steamidra { };` from `mkHost.specialArgs`.

4. `hosts/nixos-pc/gaming.nix`:
   - Set `programs.steamidra.enable = true;`.
   - Removed `steamidra` parameter from `{ pkgs, ... }:`.
   - Removed `steamidra` package from `environment.systemPackages`, retaining `pkgs.heroic`.

## Completed Tasks and Persisted Checkbox Updates

All 18 implementation tasks in `openspec/changes/extract-steamidra-nixos-module/tasks.md` have been completed and marked `- [x]`:

- [x] Create `modules/programs/steamidra/default.nix` defining the module skeleton with `options.programs.steamidra.enable` using `lib.mkEnableOption "SteaMidra"` (defaulting to `false`). <!-- sdd-owner: implementation -->
- [x] Add `options.programs.steamidra.package` in `modules/programs/steamidra/default.nix` typed as `lib.types.package`, with `default = pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { })`, `defaultText = lib.literalExpression "pkgs.steamidra"`, and documentation noting runtime graphics and X11/XWayland prerequisites. <!-- sdd-owner: implementation -->
- [x] Implement conditional configuration in `modules/programs/steamidra/default.nix` under `lib.mkIf cfg.enable` containing the platform assertion (`pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64` with message `"programs.steamidra is only supported on x86_64-linux."`) and adding `cfg.package` to `environment.systemPackages`. <!-- sdd-owner: implementation -->
- [x] Register `./steamidra` in the `imports` list of `modules/programs/default.nix`. <!-- sdd-owner: implementation -->
- [x] Introduce shared bindings in the `let` block of `flake.nix`: `steamidraPackage = pkgs.callPackage ./pkgs/steamidra { };`, `steamidraOverlay = final: _prev: { steamidra = final.callPackage ./pkgs/steamidra { }; };`, and `steamidraModule = ./modules/programs/steamidra;`. <!-- sdd-owner: implementation -->
- [x] Export `packages.${system}.steamidra = steamidraPackage;`, `overlays.steamidra = steamidraOverlay;`, `overlays.default = steamidraOverlay;`, `nixosModules.steamidra = steamidraModule;`, and `nixosModules.default = steamidraModule;` in `flake.nix`. <!-- sdd-owner: implementation -->
- [x] Remove `steamidra = pkgs.callPackage ./pkgs/steamidra { };` from `specialArgs` inside `mkHost` in `flake.nix`. <!-- sdd-owner: implementation -->
- [x] Migrate `hosts/nixos-pc/gaming.nix` to enable `programs.steamidra.enable = true;`, remove `steamidra` from the function argument list (`{ pkgs, ... }:`), and remove `steamidra` from `environment.systemPackages` while keeping `pkgs.heroic`. <!-- sdd-owner: implementation -->
- [x] Stage all new and modified files (`modules/programs/steamidra/default.nix`, `modules/programs/default.nix`, `flake.nix`, and `hosts/nixos-pc/gaming.nix`) with `git add -A` to ensure git-tracked flake evaluation. <!-- sdd-owner: implementation -->
- [x] Verify public outputs and aliases: evaluate `.#packages.x86_64-linux.steamidra.name` (expect `"steamidra-6.6.6"`), evaluate `nixosModules.default == nixosModules.steamidra` (expect `true`), and evaluate overlay aliases equality and derivation matching (`named.drvPath == default.drvPath`). <!-- sdd-owner: implementation -->
- [x] Verify external module-only evaluation with fallback: evaluate a standalone `nixosSystem` targeting `x86_64-linux` importing `nixosModules.steamidra` with `programs.steamidra.enable = true` without overlays or `specialArgs`, confirming `enable == true`, `package.name == "steamidra-6.6.6"`, and presence in `environment.systemPackages`. <!-- sdd-owner: implementation -->
- [x] Verify custom package override behavior: evaluate external `nixosSystem` with `programs.steamidra.package = pkgs.hello` and verify `pkgs.hello` is added to `environment.systemPackages` instead of the default package. <!-- sdd-owner: implementation -->
- [x] Verify platform assertion negative and disabled behavior: evaluate an `aarch64-linux` fixture with `enable = false` (succeeds) and with `enable = true` (fails with assertion `"programs.steamidra is only supported on x86_64-linux."`). <!-- sdd-owner: implementation -->
- [x] Verify repository host configuration states: evaluate `programs.steamidra.enable` across `nixos-pc` (`true`), `loon-laptop` (`false`), and `korosoft` (`false`), and confirm package closure membership only on `nixos-pc`. <!-- sdd-owner: implementation -->
- [x] Verify subsystem policy non-mutation: inspect `modules/programs/steamidra/default.nix` to confirm complete absence of definitions for `hardware.*`, `services.xserver.*`, `users.*`, `systemd.tmpfiles.*`, and networking. <!-- sdd-owner: implementation -->
- [x] Run `nix flake check --no-build` to validate flake evaluation and configuration structure. <!-- sdd-owner: implementation -->
- [x] Build SteaMidra derivation using `nix build .#steamidra` and verify package build output targets (read-only): executable `/bin/steamidra` (read-only), desktop entry `/share/applications/steamidra.desktop` (read-only), and icon asset `/share/icons/hicolor/256x256/apps/steamidra.png` (read-only). <!-- sdd-owner: implementation -->
- [x] Build host system configuration using `nixos-rebuild build --flake .#nixos-pc` to confirm full build and integration success. <!-- sdd-owner: implementation -->

## Verification Evidence

| Step | Command | Result / Evidence | Status |
|------|---------|-------------------|--------|
| Public package name | `nix eval .#packages.x86_64-linux.steamidra.name` | `"steamidra-6.6.6"` | PASS |
| Module alias equality | `nix eval --impure --expr 'let flake = builtins.getFlake (toString ./.); in flake.nixosModules.default == flake.nixosModules.steamidra'` | `true` | PASS |
| Overlay alias matching | `nix eval --impure --expr 'let ... in { named = named.name; default = default.name; sameDrv = named.drvPath == default.drvPath; }'` | `{ default = "steamidra-6.6.6"; named = "steamidra-6.6.6"; sameDrv = true; }` | PASS |
| External module-only evaluation | `nix eval --impure --expr '<standalone nixosSystem with flake.nixosModules.steamidra and enable = true>'` | `{ enable = true; inSysPackages = true; pkgName = "steamidra-6.6.6"; }` | PASS |
| Custom package override | `nix eval --impure --expr '<standalone nixosSystem with programs.steamidra.package = pkgs.hello>'` | `{ hasDefaultSteamidra = false; hasHello = true; pkgName = "hello-2.12.3"; }` | PASS |
| Platform assertion negative | `nix eval --impure --expr '<aarch64-linux fixture with enable = true>'` | `Failed assertions: - programs.steamidra is only supported on x86_64-linux.` | PASS |
| Platform assertion disabled | `nix eval --impure --expr '<aarch64-linux fixture with enable = false>'` | `{ assertionCount = 1371; enable = false; failedAssertions = [ ]; }` | PASS |
| Host enable & package closure | `nix eval --impure --expr '<checkHost across nixos-pc, loon-laptop, korosoft>'` | `[ { enabled = true; hasPkg = true; host = "nixos-pc"; } { enabled = false; hasPkg = false; host = "loon-laptop"; } { enabled = false; hasPkg = false; host = "korosoft"; } ]` | PASS |
| Policy non-mutation inspection | Read `modules/programs/steamidra/default.nix` | Zero definitions under `hardware.*`, `services.xserver.*`, `users.*`, `systemd.tmpfiles.*`, `networking.*`. | PASS |
| Flake check | `nix flake check --no-build` | `all checks passed!` | PASS |
| Standalone package build | `nix build .#steamidra` | Result directory built with `/bin/steamidra` (executable), `/share/applications/steamidra.desktop`, and `/share/icons/hicolor/256x256/apps/steamidra.png`. | PASS |
| Host system build | `nixos-rebuild build --flake .#nixos-pc` | Built successfully: `/nix/store/pxq8r57nzyfya06nlarsv061b15a6y8y-nixos-system-nixos-pc-26.05.20260814.02e0898`. | PASS |

## Deviations from Design

None. All implementation and verification steps executed exactly as specified in `design.md` and `tasks.md`.

## Remaining Tasks

Zero remaining tasks. All 18 implementation tasks are complete.

## Workload and PR Boundary

- Lines changed in source: 55 insertions, 4 deletions (59 total lines changed across 4 files).
- Within estimated 45–55 line range and well under the 400-line review budget.
- Clean single-PR boundary. No chained PRs required.
- Staged only source files: `flake.nix`, `hosts/nixos-pc/gaming.nix`, `modules/programs/default.nix`, and `modules/programs/steamidra/default.nix`.
- Runtime state `.pi/` excluded from git staging per local exclusion rules.
