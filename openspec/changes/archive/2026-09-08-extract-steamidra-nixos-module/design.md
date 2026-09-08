# Design: Extract SteaMidra NixOS Module

**Change ID:** `extract-steamidra-nixos-module`
**Artifact:** Design
**Scope:** SteaMidra package exposure, standalone module, and `nixos-pc` migration

## 1. Design Summary

Expose the existing SteaMidra derivation through three independent but source-consistent interfaces:

1. Keep `packages.x86_64-linux.steamidra` for direct package consumers.
2. Add `overlays.steamidra` and alias `overlays.default` to the same overlay function.
3. Add `nixosModules.steamidra` and alias `nixosModules.default` to the same standalone module path.

The standalone module will declare only `programs.steamidra.enable` and `programs.steamidra.package`. Its enabled configuration will add the selected package to `environment.systemPackages` and assert the supported platform. It will not configure graphics, display, users, filesystems, tmpfiles, hardware, networking, or any host-specific state.

`nixos-pc` will consume this public option interface instead of receiving the derivation through `specialArgs`. The module remains globally discoverable inside this repository through `modules/programs/default.nix`, but disabled on every host unless explicitly enabled.

## 2. Architectural Decisions

### 2.1 One package source, three consumption interfaces

`pkgs/steamidra/default.nix` remains the sole package implementation and is not modified. `flake.nix` will introduce shared bindings for the public interface:

```nix
steamidraPackage = pkgs.callPackage ./pkgs/steamidra { };
steamidraOverlay = final: _prev: {
  steamidra = final.callPackage ./pkgs/steamidra { };
};
steamidraModule = ./modules/programs/steamidra;
```

The outputs will use those bindings:

```nix
packages.${system}.steamidra = steamidraPackage;

overlays = {
  steamidra = steamidraOverlay;
  default = steamidraOverlay;
};

nixosModules = {
  steamidra = steamidraModule;
  default = steamidraModule;
};
```

Using the same binding for each named/default pair makes the aliases structurally identical rather than duplicating equivalent expressions. The overlay uses `final.callPackage`, so downstream overrides of package dependencies remain effective. The direct package output continues to use this flake's pinned Nixpkgs package set.

No default package output is added or changed; `nix build .#steamidra` continues resolving the existing named package output for `x86_64-linux`.

### 2.2 Source-relative fallback keeps the module standalone

The module's package option will resolve in this order:

```nix
default = pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { });
defaultText = lib.literalExpression "pkgs.steamidra";
```

This gives overlay users conventional `pkgs.steamidra` override behavior while allowing module-only consumers to evaluate and build without an overlay or `specialArgs`. The relative path is resolved from `modules/programs/steamidra/default.nix` to the existing package source.

The fallback must not refer to `self`, flake inputs, repository host modules, or personal configuration. Nix path closure semantics will retain `pkgs/steamidra` when the exported module path is consumed from another flake.

### 2.3 Activation is fully guarded by `enable`

The module shape will be:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.steamidra;
in
{
  options.programs.steamidra = {
    enable = lib.mkEnableOption "SteaMidra";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { });
      defaultText = lib.literalExpression "pkgs.steamidra";
      description = ''
        The SteaMidra package to install. SteaMidra requires graphics
        acceleration and an X11 or XWayland-capable display environment;
        those prerequisites remain the responsibility of the host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          pkgs.stdenv.hostPlatform.isLinux
          && pkgs.stdenv.hostPlatform.isx86_64;
        message = "programs.steamidra is only supported on x86_64-linux.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
  };
}
```

`mkEnableOption` supplies `default = false`. Placing both the assertion and package installation inside the same `mkIf` guarantees that importing the module while disabled emits neither configuration. The package option remains overridable even though only the selected package is installed.

### 2.4 Platform policy is diagnostic, not configuration

The derivation's existing `meta.platforms = [ "x86_64-linux" ];` remains unchanged. The module adds a NixOS assertion only when enabled because package metadata alone can otherwise produce a less direct unsupported-platform failure.

The module will not try to make unsupported systems work and will not enable graphics or display capabilities. The exact assertion message is part of the public contract.

### 2.5 Internal and external users consume the same module

`modules/programs/default.nix` imports `./steamidra`, making the option available to repository hosts. `hosts/nixos-pc/gaming.nix` then enables `programs.steamidra.enable = true` and leaves `pkgs.heroic` as its only direct package entry.

The `steamidra` function argument is removed from `gaming.nix`, and the corresponding entry is removed from `mkHost.specialArgs`. No overlay is added to repository hosts: this deliberately exercises the same source-relative fallback supported for external module-only consumers.

## 3. Data and Evaluation Flow

### Direct package flow

```text
packages.x86_64-linux.steamidra
  -> steamidraPackage
  -> pkgs.callPackage ./pkgs/steamidra {}
  -> existing pinned 6.6.6 derivation
```

### Overlay flow

```text
overlays.default / overlays.steamidra
  -> same steamidraOverlay function
  -> consumer final.callPackage ./pkgs/steamidra {}
  -> consumer pkgs.steamidra
```

### Standalone module flow without overlay

```text
nixosModules.default / nixosModules.steamidra
  -> same modules/programs/steamidra path
  -> programs.steamidra.enable = true
  -> package option sees no pkgs.steamidra
  -> source-relative pkgs.callPackage fallback
  -> cfg.package appended to environment.systemPackages
```

### Module flow with overlay or custom package

```text
consumer pkgs.steamidra or explicit programs.steamidra.package
  -> package option resolves selected derivation
  -> enable guard validates x86_64-linux
  -> only selected derivation enters environment.systemPackages
```

### Internal host flow

```text
modules/default.nix
  -> modules/programs/default.nix
  -> modules/programs/steamidra/default.nix
  -> nixos-pc gaming.nix enables option
  -> loon-laptop and korosoft retain false default
```

## 4. File-Level Change Plan

### `flake.nix`

- Add `steamidraPackage`, `steamidraOverlay`, and `steamidraModule` bindings in the existing `let` block.
- Reuse `steamidraPackage` in `packages.${system}.steamidra`.
- Export `overlays.steamidra` and `overlays.default` using the same overlay binding.
- Export `nixosModules.steamidra` and `nixosModules.default` using the same module-path binding.
- Remove only the SteaMidra entry from `mkHost.specialArgs`.
- Preserve all other package outputs, inputs, hosts, and special arguments unchanged.

### `modules/programs/steamidra/default.nix` (new)

- Define the standalone module shown in section 2.3.
- Accept only standard NixOS module arguments (`config`, `lib`, `pkgs`, and `...`).
- Declare the disabled-by-default enable option and overridable package option.
- Install only `cfg.package` when enabled.
- Guard the exact platform assertion with the enable option.
- Document graphics acceleration and X11/XWayland as consumer-managed prerequisites.

### `modules/programs/default.nix`

- Add `./steamidra` to the existing `imports` list.
- Make no changes to existing program modules or their ordering-sensitive behavior.

### `hosts/nixos-pc/gaming.nix`

- Change arguments from `{ pkgs, steamidra, ... }` to `{ pkgs, ... }`.
- Add `programs.steamidra.enable = true;`.
- Remove `steamidra` from `environment.systemPackages`; retain `pkgs.heroic`.
- Leave the independent Steam/Millennium settings unchanged.

### Explicitly unchanged

- `pkgs/steamidra/default.nix`, including version, hash, wrapper, runtime HOME storage, desktop entry, icon, and platform metadata.
- All graphics, display, user, hardware, tmpfiles, filesystem, networking, and kernel configuration.
- `loon-laptop`, `korosoft`, and all unrelated package/module interfaces.

## 5. Public Contracts

| Interface | Contract |
| --- | --- |
| `packages.x86_64-linux.steamidra` | Existing SteaMidra 6.6.6 derivation remains directly buildable. |
| `overlays.steamidra` | Overlay adds overridable `pkgs.steamidra`. |
| `overlays.default` | Exact alias of `overlays.steamidra`. |
| `nixosModules.steamidra` | Standalone module path requiring no flake-specific arguments. |
| `nixosModules.default` | Exact alias of `nixosModules.steamidra`. |
| `programs.steamidra.enable` | Boolean, default false; controls all emitted configuration. |
| `programs.steamidra.package` | Package, defaults to overlay package or source-relative fallback. |
| Unsupported enabled platform | Evaluation fails with the specified assertion message. |
| Enabled supported platform | Adds exactly `cfg.package` to `environment.systemPackages`. |

## 6. Verification Design

The repository has no dedicated Nix unit-test harness, so verification uses focused pure evaluation/build commands plus `nix flake check`. No new test fixture or unrelated check framework is introduced.

Before any flake command, stage the new module with `git add -A`; otherwise the flake source will omit it.

### 6.1 Output and alias checks

- Evaluate `.#packages.x86_64-linux.steamidra.name`; expect `steamidra-6.6.6`.
- Evaluate equality of `nixosModules.default` and `nixosModules.steamidra`; expect true.
- Evaluate both overlay aliases against fresh Nixpkgs package sets and compare their SteaMidra derivation paths; expect equal paths and package name `steamidra-6.6.6`.

Representative overlay expression:

```nix
let
  flake = builtins.getFlake (toString ./.);
  withOverlay = overlay: import flake.inputs.nixpkgs {
    system = "x86_64-linux";
    overlays = [ overlay ];
  };
  named = (withOverlay flake.overlays.steamidra).steamidra;
  default = (withOverlay flake.overlays.default).steamidra;
in
{
  named = named.name;
  default = default.name;
  same = named.drvPath == default.drvPath;
}
```

Run this with `nix eval --impure --expr` so the working-tree flake can be addressed directly.

### 6.2 External module-only evaluation

Construct a fresh `nixpkgs.lib.nixosSystem` whose modules list contains only the normal NixOS base modules supplied by `nixosSystem`, `flake.nixosModules.steamidra`, and a small inline configuration enabling SteaMidra. Do not pass overlays or `specialArgs`.

Evaluate and verify:

- `config.programs.steamidra.enable == true`.
- `config.programs.steamidra.package.name == "steamidra-6.6.6"`.
- The selected package is present in `config.environment.systemPackages`.
- A second fixture setting `programs.steamidra.package = pkgs.hello` installs `hello` instead of the default package.

This fixture is the decisive check that the source-relative fallback works outside the repository's aggregate module tree.

### 6.3 Disabled and platform behavior

- Evaluate an `aarch64-linux` fixture importing the module with the default disabled value; expect successful evaluation and `enable == false`.
- Force `config.system.build.toplevel.drvPath` for the same fixture with `enable = true`; expect failure containing exactly `programs.steamidra is only supported on x86_64-linux.`.
- Inspect the standalone module diff and search it for definitions under `hardware`, `services.xserver`, `users`, `systemd.tmpfiles`, networking, boot, and filesystem namespaces; expect none. Runtime prerequisite terms may appear only in option documentation.

### 6.4 Repository integration

Run:

```text
nix eval .#nixosConfigurations.nixos-pc.config.programs.steamidra.enable
nix eval .#nixosConfigurations.loon-laptop.config.programs.steamidra.enable
nix eval .#nixosConfigurations.korosoft.config.programs.steamidra.enable
nix flake check --no-build
nix build .#steamidra
nixos-rebuild build --flake .#nixos-pc
```

Expected enable values are `true`, `false`, and `false`. Also evaluate package membership for each host: present on `nixos-pc`, absent on the other two. Inspect the built package for `bin/steamidra`, the desktop file, and the 256x256 icon.

## 7. Rollout and Rollback

Implement all four file changes as one atomic work unit because removing `specialArgs` before migrating `gaming.nix`, or importing the module before creating its file, leaves the flake temporarily invalid. Stage the new module before evaluation, then run focused external-interface checks before the broader flake and host builds.

No data migration or activation-time state change is introduced. Rollback restores the direct `gaming.nix` package entry and SteaMidra `specialArgs` binding, then removes the module import and public module/overlay outputs. Existing user-managed runtime data under `$HOME/.local/share/SteaMidra` remains untouched in either direction.

## 8. Risks and Controls

- **Fallback path breakage:** verify through a fresh module-only `nixosSystem` without overlays or special arguments.
- **Alias drift:** bind each default/named pair to one shared Nix value and verify equality.
- **Unexpected host activation:** retain the false default and evaluate all three repository hosts.
- **Policy leakage:** keep the enabled config to one assertion and one package-list assignment; review the module for forbidden namespaces.
- **Unsupported architecture confusion:** force the NixOS toplevel in the negative fixture and check the exact assertion text.
- **Review size:** the implementation remains four focused files and is expected to remain well below the 400-line review budget, so no delivery-strategy gate is required.
