# Tasks: Extract SteaMidra NixOS Module

**Change ID:** `extract-steamidra-nixos-module`
**Artifact:** Tasks
**Status:** Ready for Apply

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 45–55 lines |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | single PR |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

```text
Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low
```

## Tasks

### Phase 1: Standalone SteaMidra NixOS Module

- [x] Create `modules/programs/steamidra/default.nix` defining the module skeleton with `options.programs.steamidra.enable` using `lib.mkEnableOption "SteaMidra"` (defaulting to `false`). <!-- sdd-owner: implementation -->
- [x] Add `options.programs.steamidra.package` in `modules/programs/steamidra/default.nix` typed as `lib.types.package`, with `default = pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { })`, `defaultText = lib.literalExpression "pkgs.steamidra"`, and documentation noting runtime graphics and X11/XWayland prerequisites. <!-- sdd-owner: implementation -->
- [x] Implement conditional configuration in `modules/programs/steamidra/default.nix` under `lib.mkIf cfg.enable` containing the platform assertion (`pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64` with message `"programs.steamidra is only supported on x86_64-linux."`) and adding `cfg.package` to `environment.systemPackages`. <!-- sdd-owner: implementation -->

### Phase 2: Repository Module Registration & Flake Exports

- [x] Register `./steamidra` in the `imports` list of `modules/programs/default.nix`. <!-- sdd-owner: implementation -->
- [x] Introduce shared bindings in the `let` block of `flake.nix`: `steamidraPackage = pkgs.callPackage ./pkgs/steamidra { };`, `steamidraOverlay = final: _prev: { steamidra = final.callPackage ./pkgs/steamidra { }; };`, and `steamidraModule = ./modules/programs/steamidra;`. <!-- sdd-owner: implementation -->
- [x] Export `packages.${system}.steamidra = steamidraPackage;`, `overlays.steamidra = steamidraOverlay;`, `overlays.default = steamidraOverlay;`, `nixosModules.steamidra = steamidraModule;`, and `nixosModules.default = steamidraModule;` in `flake.nix`. <!-- sdd-owner: implementation -->
- [x] Remove `steamidra = pkgs.callPackage ./pkgs/steamidra { };` from `specialArgs` inside `mkHost` in `flake.nix`. <!-- sdd-owner: implementation -->

### Phase 3: Host Migration (`nixos-pc`)

- [x] Migrate `hosts/nixos-pc/gaming.nix` to enable `programs.steamidra.enable = true;`, remove `steamidra` from the function argument list (`{ pkgs, ... }:`), and remove `steamidra` from `environment.systemPackages` while keeping `pkgs.heroic`. <!-- sdd-owner: implementation -->

### Phase 4: Verification & Build Validation

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
