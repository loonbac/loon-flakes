# SteaMidra Specification

## Purpose

Define a standalone, reusable NixOS module and flake packaging interface for SteaMidra (Steam game setup and manifest tool). The interface enables both internal repository hosts and external consumers to install and configure SteaMidra declaratively on `x86_64-linux` without coupling to personal host configurations, overlays, or special argument passing, while strictly preserving consumer sovereignty over graphics, display, user, and filesystem policies.

## Requirements

### Requirement: Standalone Flake Module Export

The flake MUST export `nixosModules.steamidra` and `nixosModules.default` (aliased to `steamidra`), allowing downstream NixOS configurations to import the SteaMidra module independently without inheriting personal host modules, repository-specific `specialArgs`, or external inputs.

#### Scenario: External consumer imports module without overlays or specialArgs

- GIVEN an external NixOS configuration on `x86_64-linux` importing `loon-flakes.nixosModules.steamidra`
- WHEN `programs.steamidra.enable` is set to `true` without configuring overlays or `specialArgs`
- THEN the configuration evaluates successfully
- AND the SteaMidra package is built and resolved hermetically via the fallback mechanism
- AND `nixosModules.default` resolves to the identical module definition as `nixosModules.steamidra`.

### Requirement: Flake Overlays Export

The flake MUST export `overlays.steamidra` and `overlays.default` (aliased to `steamidra`), providing an overridable `pkgs.steamidra` attribute matching the pinned package derivation.

#### Scenario: Downstream consumer applies overlay

- GIVEN a Nixpkgs package set configured with `nixpkgs.overlays = [ loon-flakes.overlays.default ]` (or `loon-flakes.overlays.steamidra`)
- WHEN querying or building `pkgs.steamidra`
- THEN the attribute resolves cleanly to the SteaMidra package derivation
- AND `overlays.default` and `overlays.steamidra` produce identical package attributes.

### Requirement: Pinned Package Output and Direct Consumption

The flake MUST continue to provide `packages.x86_64-linux.steamidra` resolving to the existing pinned package derivation (version `6.6.6`), maintaining the official AppImage unpackaging, FHS execution wrapper, desktop file, icon installation, and runtime wrapper behavior without modification.

#### Scenario: Direct package evaluation and build

- GIVEN a flake evaluation targeting `packages.x86_64-linux.steamidra`
- WHEN evaluated and built with `nix build .#steamidra`
- THEN the package builds successfully
- AND the resulting derivation contains executable `/bin/steamidra`, desktop entry `/share/applications/steamidra.desktop`, and icon `/share/icons/hicolor/256x256/apps/steamidra.png`
- AND the package metadata restricts supported platforms to `x86_64-linux`.

### Requirement: Opt-In NixOS Configuration Interface

The NixOS module MUST expose options under the `programs.steamidra` namespace:
1. `programs.steamidra.enable`: A boolean option that MUST default to `false`.
2. `programs.steamidra.package`: A package option that MUST default to `pkgs.steamidra or (pkgs.callPackage ../../../pkgs/steamidra { })` with literal expression default text `"pkgs.steamidra"`.

When `programs.steamidra.enable` is `false`, the module MUST NOT add any packages to `environment.systemPackages` and MUST NOT emit any system assertions or configurations.

When `programs.steamidra.enable` is `true`, the module MUST add the package specified by `programs.steamidra.package` to `environment.systemPackages`.

#### Scenario: Disabled module leaves system packages unmodified

- GIVEN a NixOS configuration that imports `nixosModules.steamidra`
- WHEN `programs.steamidra.enable` remains at its default value `false`
- THEN no SteaMidra package is added to `environment.systemPackages`
- AND evaluating the configuration incurs no closure changes related to SteaMidra.

#### Scenario: Enabled module installs default package

- GIVEN a NixOS configuration on `x86_64-linux` that imports `nixosModules.steamidra`
- WHEN `programs.steamidra.enable` is set to `true`
- THEN the default SteaMidra package is added to `environment.systemPackages`
- AND the binary `steamidra` and desktop entry become available in the system environment.

#### Scenario: Enabled module with custom package override

- GIVEN a NixOS configuration on `x86_64-linux` that imports `nixosModules.steamidra`
- WHEN `programs.steamidra.enable` is set to `true` and `programs.steamidra.package` is set to a custom package derivation
- THEN the custom package derivation is added to `environment.systemPackages` instead of the default package.

### Requirement: Platform Architecture Assertion

When `programs.steamidra.enable` is `true`, the module MUST evaluate an assertion verifying that the host platform is `x86_64-linux` (`pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64`). If evaluated on any unsupported platform, NixOS configuration evaluation MUST fail with the message `"programs.steamidra is only supported on x86_64-linux."`.

When `programs.steamidra.enable` is `false`, the platform assertion MUST NOT be triggered on non-x86_64 platforms.

#### Scenario: Evaluation on x86_64-linux succeeds

- GIVEN a NixOS configuration targeting `x86_64-linux`
- WHEN `programs.steamidra.enable` is set to `true`
- THEN evaluation passes without triggering platform assertion failures.

#### Scenario: Evaluation on non-x86_64 or non-Linux fails evaluation

- GIVEN a NixOS configuration targeting an unsupported platform (e.g. `aarch64-linux` or `x86_64-darwin`)
- WHEN `programs.steamidra.enable` is set to `true`
- THEN configuration evaluation fails with the assertion error `"programs.steamidra is only supported on x86_64-linux."`.

#### Scenario: Evaluation on unsupported platform with module disabled succeeds

- GIVEN a NixOS configuration targeting an unsupported platform
- WHEN `programs.steamidra.enable` is `false` (or left default)
- THEN configuration evaluation succeeds without triggering the platform assertion.

### Requirement: Subsystem and Host Policy Non-Mutation

The SteaMidra module MUST NOT configure, override, or set defaults for:
- Graphics or hardware acceleration options (`hardware.graphics`, `hardware.opengl`, GPU drivers, or Mesa libraries).
- Display servers, window managers, or compositors (`services.xserver`, XWayland, Wayland compositor configurations).
- System users, groups, or credentials (`users.users`, `users.groups`).
- User home directory paths or environment dotfiles.
- System or user temporary files (`systemd.tmpfiles.*`).
- Network, firewall, or kernel module settings.

All graphics acceleration and display server prerequisites MUST remain the exclusive responsibility of the consumer host configuration. Option documentation for `programs.steamidra.package` MUST explicitly document these runtime prerequisites.

#### Scenario: Host graphics and compositor sovereignty is preserved

- GIVEN a NixOS system configuration enabling `programs.steamidra.enable = true`
- WHEN the system configuration is evaluated
- THEN options under `hardware.graphics`, `hardware.opengl`, `services.xserver`, `users.*`, and `systemd.tmpfiles.*` contain no definitions introduced by the SteaMidra module
- AND the module's option description provides explicit documentation regarding the need for graphics acceleration and an X11/XWayland display server.

### Requirement: Repository Host Integration and Migration

The repository configuration MUST migrate existing SteaMidra consumption on `nixos-pc` to the new module API, and remove internal `specialArgs.steamidra` passing:
1. `modules/programs/default.nix` MUST import the `./steamidra` module so that all repository hosts have access to `programs.steamidra`.
2. `hosts/nixos-pc/gaming.nix` MUST set `programs.steamidra.enable = true;` and remove direct package references and the `steamidra` parameter.
3. `flake.nix` MUST remove `steamidra = pkgs.callPackage ./pkgs/steamidra { };` from `specialArgs` in `mkHost`.
4. Other repository hosts (`loon-laptop` and `korosoft`) MUST remain with `programs.steamidra.enable = false` by default, producing no evaluation or package closure changes.

#### Scenario: nixos-pc evaluates and builds with module enabled

- GIVEN the repository flake configuration for host `nixos-pc`
- WHEN evaluated with `nix eval .#nixosConfigurations.nixos-pc.config.programs.steamidra.enable`
- THEN it evaluates to `true`
- AND the SteaMidra package is present in `environment.systemPackages` of `nixos-pc`
- AND no `steamidra` attribute is required or passed in `specialArgs`.

#### Scenario: loon-laptop and korosoft remain untouched

- GIVEN the repository flake configurations for hosts `loon-laptop` and `korosoft`
- WHEN evaluated
- THEN `programs.steamidra.enable` evaluates to `false`
- AND no SteaMidra package is present in their `environment.systemPackages`.

## Acceptance Criteria

1. **Flake Output Compatibility**:
   - `nix eval .#nixosModules.steamidra` evaluates to the SteaMidra NixOS module function.
   - `nix eval .#nixosModules.default` evaluates to the exact same module.
   - `nix eval .#overlays.default` and `nix eval .#overlays.steamidra` evaluate to valid Nixpkgs overlay functions exposing `steamidra`.
   - `nix eval .#packages.x86_64-linux.steamidra.name` evaluates to `"steamidra-6.6.6"`.
2. **Module Behavioral Purity**:
   - `programs.steamidra.enable` defaults to `false`.
   - `programs.steamidra.package` defaults to `pkgs.steamidra` with a relative fallback to `../../../pkgs/steamidra`.
   - Evaluation with `programs.steamidra.enable = true` on `x86_64-linux` adds only `cfg.package` to `environment.systemPackages`.
   - Evaluation on non-`x86_64-linux` systems with `enable = true` triggers a clear assertion failure.
   - The module introduces zero configuration into `hardware.*`, `services.xserver.*`, `users.*`, or `systemd.tmpfiles.*`.
3. **Internal Repository Host Migration**:
   - `nixos-pc` evaluates cleanly with `programs.steamidra.enable = true`.
   - `specialArgs.steamidra` is eliminated from `flake.nix`.
   - `loon-laptop` and `korosoft` evaluate cleanly with `programs.steamidra.enable = false` without containing the package.
   - `nix flake check --no-build` passes with zero errors.
