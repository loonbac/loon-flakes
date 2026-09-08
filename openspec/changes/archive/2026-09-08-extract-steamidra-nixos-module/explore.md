# Exploration Notes: Extract SteaMidra NixOS Module and Package Interface

**Change ID**: `extract-steamidra-nixos-module`
**Date**: 2026-09-08 (Corrective Rerun)
**Status**: Completed
**Review Budget Lines**: 400 lines (Forecast: ~45–55 lines total diff)

---

## 1. Executive Summary & Approved Scope

The goal of this change is to extract **SteaMidra** ([Midrags/SFF](https://github.com/Midrags/SFF)) into a standalone, externally consumable NixOS module and package interface.

### Scope Guardrails
- **Standalone public interface**: Pinned `x86_64-linux` package derivation + opt-in NixOS module exported via `flake.nix`.
- **Zero mutation of global policies**:
  - `programs.steamidra` MUST NOT set or default `hardware.graphics.enable`, `hardware.opengl.enable`, or any graphics subsystem options.
  - MUST NOT configure, toggle, or assume XWayland or any specific compositor/window manager settings.
  - MUST NOT configure host hardware, users, groups, or HOME policies (no tmpfiles, no hardcoded user paths).
- **Runtime prerequisites boundaries**:
  - Runtime prerequisites (functional OpenGL/Vulkan acceleration and an X11/XWayland display environment) belong exclusively to consumer documentation and clear option descriptions.
  - Activation must not depend on host-specific assumptions or trigger side-effects across the consumer's configuration.
- **No personal/host assumptions**: Zero hardcoded usernames (`loonbac`), user home paths (`/home/loonbac`), or host-specific hardware paths.
- **Existing consumer compatibility**: Keep `nixos-pc` working identically as a consumer.
- **Strict non-goals**:
  - Do NOT refactor other personal modules (`modules/system`, `modules/networking`, `modules/services`, `modules/wayland`, `modules/users`, or other programs in `modules/programs`).
  - Do NOT alter personal hardware profiles (`hosts/loon-laptop`, `hosts/korosoft`, `hosts/nixos-pc/platform.nix`).
  - Do NOT touch unrelated packages or network configurations.

---

## 2. Current State Analysis

### Package Implementation (`pkgs/steamidra/default.nix`)
- **Upstream format**: PyInstaller bundle inside an AppImage, distributed as a GitHub release zip (`SteaMidra-6.6.6-linux.zip`).
- **NixOS wrapping**:
  1. Unzips release payload and extracts AppImage via `appimageTools.extract`.
  2. Wraps payload inside `buildFHSEnv` with required dynamic libraries (NSS, NSPR, ALSA, XCB, X11, libGL, GTK3, Mesa, Wayland, etc.).
  3. Uses an internal launch script forcing `QT_QPA_PLATFORM=xcb` because the bundled Qt 6.10 Wayland platform plugin segfaults under Wayland compositors like niri. This is isolated to the process execution environment.
  4. The outer wrapper script dynamically initializes `$HOME/.local/share/SteaMidra` and sets `APPIMAGE="$HOME/.local/share/SteaMidra/SteaMidra.AppImage"`:
     ```bash
     mkdir -p "${HOME}/.local/share/SteaMidra"
     export APPIMAGE="${HOME}/.local/share/SteaMidra/SteaMidra.AppImage"
     exec ${fhs}/bin/steamidra-fhs "$@"
     ```
  5. Installs desktop entry (`steamidra.desktop`) and application icon (`steamidra.png`).
- **Current purity**: The derivation itself is already pure and parameter-free, relying strictly on standard Nixpkgs. It has NO hardcoded usernames or system paths.

### Flake Exposure (`flake.nix`)
- Currently exported under `packages.${system}.steamidra = pkgs.callPackage ./pkgs/steamidra { };`.
- Injected into `specialArgs` in `mkHost`:
  ```nix
  specialArgs = {
    ...
    steamidra = pkgs.callPackage ./pkgs/steamidra { };
  };
  ```
- **Gaps for external consumers**:
  - No `nixosModules` output is exposed by `flake.nix`.
  - No `overlays` output is exposed by `flake.nix`.
  - There is no NixOS module for SteaMidra anywhere in the repository.

### Host Integration (`hosts/nixos-pc/gaming.nix`)
- Currently receives `steamidra` directly via module arguments (`specialArgs`):
  ```nix
  { pkgs, steamidra, ... }:
  {
    loon.programs.steam = {
      enable = true;
      spaceThemeFix.enable = true;
    };

    environment.systemPackages = [
      pkgs.heroic
      steamidra
    ];
  }
  ```
- This couples `nixos-pc` to an ad-hoc `specialArgs` injection rather than an idiomatic module option.

---

## 3. Concrete Repository Integration Choices

### 3.1. Package Exposure via Flake Outputs and Overlay

To support both flake consumers and non-flake/overlay consumers:

1. **Flake Packages**:
   - Retain `packages.x86_64-linux.steamidra = pkgs.callPackage ./pkgs/steamidra { };`.
   - The package is pinned to version `6.6.6` with SHA-256 hash `055f4a5d4775699e1dd87b57369d6ce8a29a2af04bf850583644da7a540b496f`.
   - Platform constraint is declared in derivation meta: `platforms = [ "x86_64-linux" ];`.

2. **Flake Overlays**:
   - Add `overlays.default` and `overlays.steamidra` in `flake.nix`:
     ```nix
     overlays = {
       default = final: prev: {
         steamidra = final.callPackage ./pkgs/steamidra { };
       };
       steamidra = self.overlays.default;
     };
     ```
   - This allows consumers using `nixpkgs.overlays = [ loon-flakes.overlays.default ];` to access `pkgs.steamidra` directly.

### 3.2. NixOS Module Placement and Export

1. **File Location**:
   - `modules/programs/steamidra/default.nix`
   - Following repository conventions where individual user-facing programs live under `modules/programs/<name>/default.nix`.

2. **Flake Export**:
   - Add `nixosModules` output in `flake.nix`:
     ```nix
     nixosModules = {
       steamidra = import ./modules/programs/steamidra;
       default = self.nixosModules.steamidra;
     };
     ```
   - `nixosModules.steamidra` provides an explicit target, while `nixosModules.default` provides a frictionless default import for downstream flakes consuming this repository as a module provider.

3. **In-Repo Composition**:
   - Add `./steamidra` to `modules/programs/default.nix` imports:
     ```nix
     imports = [
       ...
       ./steam
       ./steamidra
     ];
     ```
   - Because the module is opt-in (`enable = false;` by default), importing it in `modules/programs/default.nix` makes the option available across all hosts without enabling it on hosts that do not want it.

### 3.3. Module Option Namespace & API Design

#### Option Namespace: `programs.steamidra`
- **Why `programs.steamidra` instead of `loon.programs.steamidra`**:
  - `loon.*` is reserved for loonbac's personal system conventions and multi-host customizations.
  - An external consumer importing `nixosModules.steamidra` expects standard NixOS namespace conventions (`programs.<name>`).
  - SteaMidra has no naming collisions with upstream Nixpkgs (no `programs.steamidra` exists in nixpkgs).
  - Clean, idiomatic, and ready for potential future upstreaming.

#### Option Schema:
```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.steamidra;
in
{
  options.programs.steamidra = {
    enable = lib.mkEnableOption "SteaMidra (Steam game setup and manifest tool)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { });
      defaultText = lib.literalExpression "pkgs.steamidra";
      description = ''
        The SteaMidra package derivation to install.

        Note: SteaMidra requires functional graphics acceleration (such as
        `hardware.graphics.enable = true`) and an X11 or XWayland display
        server environment at runtime.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64;
        message = "programs.steamidra is only supported on x86_64-linux.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
  };
}
```

#### Architectural Strengths & Purity Boundaries:
1. **Zero Global Mutation**:
   - The module strictly adds `cfg.package` to `environment.systemPackages`.
   - It does **not** set or default `hardware.graphics.enable`, `hardware.opengl.enable`, or any graphics subsystem options.
   - It does **not** configure XWayland or compositor options.
   - It does **not** declare users, groups, tmpfiles, or filesystem paths.
2. **Zero-Overhead Package Fallback**:
   `default = pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { });`
   If an external user imports `loon-flakes.nixosModules.steamidra` without registering the overlay, it evaluates `pkgs.callPackage` hermetically from the relative path within the flake source in the Nix store. If they register the overlay, `pkgs.steamidra` is used.
3. **Dynamic User Home Handling**:
   The package's bash wrapper dynamically resolves `"${HOME}/.local/share/SteaMidra"` per-user at process execution time.
4. **Desktop Environment Integration**:
   Adding `cfg.package` to `environment.systemPackages` automatically handles desktop entries (`share/applications/steamidra.desktop`) and icon discovery (`share/icons/hicolor/...`) via standard NixOS environment linkers.

### 3.4. Platform Assertion & Runtime Prerequisites Policy

1. **Safely Detectable Architecture Assertion**:
   - `pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64`
   - SteaMidra upstream only distributes an `x86_64-linux` AppImage. Attempting to evaluate on ARM64 or Darwin will fail early with a clear message rather than a cryptic build failure.

2. **Decoupled Runtime Prerequisites**:
   - SteaMidra uses Qt 6 / PyQt6 and QtWebEngine, requiring functional hardware/graphics acceleration and an X11 or XWayland display server (since the wrapper runs with `QT_QPA_PLATFORM=xcb`).
   - Rather than forcing or defaulting system options like `hardware.graphics.enable = lib.mkDefault true;`—which would violate consumer sovereignty and could conflict with custom host setups, containers, or differing Nixpkgs releases—these prerequisites are documented clearly in the option description and user documentation.
   - Hosts remain entirely in control of their hardware, graphics driver selection, and compositor/display stack. For example, `hosts/nixos-pc/platform.nix` already configures `hardware.graphics.enable = true` alongside proprietary NVIDIA drivers independently.

### 3.5. Host Migration Path (`nixos-pc`)

1. **Update `hosts/nixos-pc/gaming.nix`**:
   - Change from:
     ```nix
     { pkgs, steamidra, ... }:
     {
       loon.programs.steam = {
         enable = true;
         spaceThemeFix.enable = true;
       };

       environment.systemPackages = [
         pkgs.heroic
         steamidra
       ];
     }
     ```
   - Change to:
     ```nix
     { pkgs, ... }:
     {
       loon.programs.steam = {
         enable = true;
         spaceThemeFix.enable = true;
       };

       programs.steamidra.enable = true;

       environment.systemPackages = [
         pkgs.heroic
       ];
     }
     ```
2. **Clean up `flake.nix` `specialArgs`**:
   - Remove `steamidra = pkgs.callPackage ./pkgs/steamidra { };` from `specialArgs` in `mkHost`.
   - All hosts inherit the module declaration from `modules/programs/default.nix`.
   - `loon-laptop` and `korosoft` have `programs.steamidra.enable = false` (the default), causing zero evaluation or closure changes for those machines.

---

## 4. Fresh-Consumer Verification Plan

### Scenario 1: External Flake Consumer (Module Only)
An external user with their own flake:
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    loon-flakes.url = "github:loonbac/loon-flakes";
  };

  outputs = { self, nixpkgs, loon-flakes }: {
    nixosConfigurations.my-desktop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        loon-flakes.nixosModules.steamidra
        {
          programs.steamidra.enable = true;
          # Consumer maintains full control over graphics and display server:
          hardware.graphics.enable = true;
        }
      ];
    };
  };
}
```
*Verification*: Works without requiring overlay injection or `specialArgs`, and does not mutate any other subsystem.

### Scenario 2: External Flake Consumer (Overlay Only)
```nix
{
  inputs.loon-flakes.url = "github:loonbac/loon-flakes";
  # In configuration.nix:
  nixpkgs.overlays = [ loon-flakes.overlays.default ];
  environment.systemPackages = [ pkgs.steamidra ];
}
```
*Verification*: `pkgs.steamidra` resolves cleanly to the derivation.

### Scenario 3: Ad-hoc CLI Execution
```bash
nix run github:loonbac/loon-flakes#steamidra
```
*Verification*: `packages.x86_64-linux.steamidra` runs via FHS.

### Scenario 4: Non-Flake Consumer
```nix
pkgs.callPackage (fetchTarball "https://github.com/loonbac/loon-flakes/archive/master.tar.gz" + "/pkgs/steamidra") { }
```
*Verification*: Standalone derivation builds cleanly with standard nixpkgs inputs.

---

## 5. Implementation Workload & Risk Assessment

- **Affected files**:
  1. `flake.nix`: ~12 lines added (`overlays`, `nixosModules`, removing `specialArgs.steamidra`).
  2. `modules/programs/default.nix`: 1 line added (`./steamidra`).
  3. `modules/programs/steamidra/default.nix`: ~30 lines added (new standalone module without graphics/hardware side effects).
  4. `hosts/nixos-pc/gaming.nix`: ~3 lines modified (enable option, remove package from list and args).
- **Estimated total diff size**: ~45–55 lines.
- **Review Budget**: 400 lines maximum. Forecast is well within budget (<15% of budget).
- **Risk Level**: Minimal. No changes to package build logic or FHS wrapper; only structural exposure and declarative option wiring with zero mutation of global host policies.
- **Verification Commands**:
  - `nix flake check --no-build`
  - `nix eval .#nixosConfigurations.nixos-pc.config.programs.steamidra.enable`
  - `nix eval .#nixosConfigurations.loon-laptop.config.programs.steamidra.enable`
  - `nix eval .#nixosModules.steamidra`
  - `nix eval .#packages.x86_64-linux.steamidra.name`
  - `nixos-rebuild build --flake .#nixos-pc`
