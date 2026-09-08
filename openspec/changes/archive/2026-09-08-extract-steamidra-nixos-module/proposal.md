# Proposal: Extract SteaMidra NixOS Module

**Change ID:** `extract-steamidra-nixos-module`
**Status:** Proposed

## Intent

Turn the existing pinned SteaMidra package into a small, standalone flake interface that external NixOS users can consume without inheriting this repository's personal host configuration. Preserve direct package installation while adding an opt-in NixOS module and overlays, then migrate the existing `nixos-pc` integration to that public module API.

## Problem Statement

SteaMidra is already packaged and exposed as `packages.x86_64-linux.steamidra`, but its in-repository host integration depends on a package passed through `specialArgs`. The flake exposes neither a reusable NixOS module nor an overlay. External consumers therefore lack an idiomatic way to enable SteaMidra declaratively, and the current host wiring unnecessarily couples package access to this repository's internal `mkHost` arguments.

This change is worth making because it creates a clear, portable product boundary around SteaMidra while removing an ad hoc integration path from `nixos-pc`. It must do so without exporting personal assumptions or taking control of consumers' graphics, display, hardware, user, or filesystem policies.

## Product Outcome

After this change:

- External flake consumers can import `nixosModules.steamidra` and enable `programs.steamidra` without an overlay, `specialArgs`, or personal repository configuration.
- Overlay consumers can use either `overlays.steamidra` or `overlays.default` to obtain `pkgs.steamidra`.
- Direct consumers retain `packages.x86_64-linux.steamidra` and can continue installing or running the pinned package.
- `nixos-pc` consumes the same opt-in module interface exposed to external users.
- Hosts that do not explicitly enable the module remain unchanged.

## Public API

The change will establish these supported interfaces:

- `nixosModules.steamidra`: standalone NixOS module.
- `overlays.steamidra`: named SteaMidra overlay.
- `overlays.default`: default overlay exposing the same package.
- `packages.x86_64-linux.steamidra`: existing pinned package output.
- `programs.steamidra.enable`: opt-in installation switch, disabled by default.
- `programs.steamidra.package`: overridable package used by the module.

The module will support only `x86_64-linux` and provide a clear evaluation-time assertion when enabled on an unsupported platform.

## Scope

### In Scope

1. Export the standalone SteaMidra NixOS module from `flake.nix`.
2. Export named and default SteaMidra overlays from `flake.nix`.
3. Preserve the existing pinned `packages.x86_64-linux.steamidra` output and package runtime behavior.
4. Add an opt-in `programs.steamidra` module that installs its selected package into `environment.systemPackages`.
5. Make the module usable with or without the SteaMidra overlay.
6. Register the disabled-by-default module in the repository's program module composition.
7. Migrate `hosts/nixos-pc/gaming.nix` to enable `programs.steamidra` and remove the SteaMidra package argument from `specialArgs`.
8. Document runtime prerequisites through option descriptions rather than enforcing host policy.

### Non-Goals

- Refactoring other packages, modules, or the broader personal NixOS repository.
- Changing SteaMidra's pinned version, source, derivation, wrapper, runtime storage, or upstream behavior.
- Enabling or changing `hardware.graphics`, legacy OpenGL options, XWayland, compositors, display managers, or drivers.
- Creating or modifying users, groups, HOME paths, tmpfiles rules, hardware settings, network settings, or host-specific paths.
- Enabling SteaMidra on `loon-laptop`, `korosoft`, or any host other than the existing `nixos-pc` consumer.
- Expanding support beyond `x86_64-linux`.

## Behavioral and Policy Invariants

- `programs.steamidra.enable` defaults to `false`.
- Importing the module alone has no package, service, hardware, user, or filesystem effect.
- Enabling the module adds only the configured SteaMidra package to the system package set.
- The module contains no hard-coded username, HOME directory, or host path.
- Runtime state remains limited to SteaMidra's existing application-managed storage under the invoking user's HOME.
- Graphics acceleration and an X11/XWayland-capable environment remain consumer responsibilities and are not mutated by the module.
- Existing package pinning and launch behavior remain unchanged.

## Affected Areas

| Area | Proposed effect |
| --- | --- |
| `flake.nix` | Add module and overlay outputs; remove the SteaMidra `specialArgs` injection while retaining the package output. |
| `modules/programs/steamidra/default.nix` | Define the standalone, disabled-by-default `programs.steamidra` module. |
| `modules/programs/default.nix` | Import the module so repository hosts can opt in. |
| `hosts/nixos-pc/gaming.nix` | Enable the module and stop receiving/installing SteaMidra through a special argument. |
| External consumers | Gain module-only, overlay, and direct-package consumption paths. |

No other host, package, module, hardware, network, or user configuration is expected to change.

## Compatibility and Migration

The existing `nixos-pc` behavior is preserved by replacing its direct `environment.systemPackages` entry with `programs.steamidra.enable = true`. Its existing independent graphics and display configuration remains authoritative. Removing the package from `specialArgs` should not affect other modules because the exploration found only the current `nixos-pc` gaming integration consuming it.

External direct-package consumers retain the existing package output. New module consumers do not need to configure an overlay because the module can fall back to constructing the package from the repository source; consumers that do configure an overlay can override or consume `pkgs.steamidra` conventionally.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The module accidentally changes graphics or display policy. | Consumer systems could conflict with custom drivers or compositor choices. | Keep module configuration limited to package installation and verify forbidden options are absent. |
| Package resolution differs between module-only and overlay consumers. | One supported consumption path may fail evaluation. | Verify both the source fallback and overlay-provided `pkgs.steamidra` interfaces. |
| Unsupported systems receive confusing build failures. | ARM or non-Linux consumers get poor diagnostics. | Assert `x86_64-linux` when the module is enabled and retain the package platform metadata. |
| Removing `specialArgs.steamidra` breaks the current host. | `nixos-pc` could fail evaluation or lose the package. | Migrate the host in the same change and evaluate/build its configuration. |
| A globally imported module affects untouched hosts. | Disabled hosts could gain packages or policy changes. | Default to disabled and verify `loon-laptop` remains disabled with no SteaMidra activation. |

The exploration forecasts approximately 45–55 changed lines across four focused implementation files, which remains well below the 400-line review budget. No delivery-strategy decision is currently required.

## Rollback

Rollback is configuration-only and does not require data migration:

1. Restore direct SteaMidra installation in `hosts/nixos-pc/gaming.nix`.
2. Restore the SteaMidra package argument in `mkHost.specialArgs`.
3. Remove the module import and public module/overlay outputs.
4. Leave the existing package derivation and `packages.x86_64-linux.steamidra` output intact.

User runtime data is not moved or transformed by this change, so reverting the module interface does not require deleting or migrating application state.

## Success Criteria

1. `packages.x86_64-linux.steamidra` still resolves to the existing pinned SteaMidra package.
2. `nixosModules.steamidra` can be imported and enabled by a fresh `x86_64-linux` NixOS consumer without an overlay or `specialArgs`.
3. `overlays.steamidra` and `overlays.default` both expose `pkgs.steamidra`.
4. `programs.steamidra` is disabled by default and installs only its selected package when enabled.
5. Enabling the module on a non-`x86_64-linux` system produces a clear unsupported-platform assertion.
6. The module does not set graphics, OpenGL, XWayland, compositor, hardware, user, group, HOME, tmpfiles, or host-specific options.
7. `nixos-pc` evaluates with `programs.steamidra.enable = true` and no SteaMidra `specialArgs` dependency.
8. Untouched hosts remain disabled and retain their existing configuration behavior.
9. `nix flake check --no-build` succeeds, and the `nixos-pc` system configuration can be built through the repository's normal NixOS build flow.
