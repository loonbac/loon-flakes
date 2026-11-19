# Project Context: loon-flakes

Initialized: 2026-09-08
Artifact Store: openspec
Workspace Root: /home/loonbac/.nixos

## Architecture & Stack Overview

- **Stack**: NixOS multi-host configuration (Nixpkgs 26.05) managed with Nix Flakes.
- **Hosts**:
  - `loon-laptop`: Dell XPS laptop (Intel iHD/i915 graphics, dedicated AC/battery power management).
  - `nixos-pc`: AMD Ryzen 7 5700X desktop with NVIDIA GPU (primary machine).
- **Repository Structure**:
  - `flake.nix` & `flake.lock`: Entrypoint flake declaring inputs, outputs, packages, and NixOS configurations.
  - `pkgs/`: Custom derivation packages (`rebuild`, `cargo-target-cache`, `pi-compaction-threshold`, etc.).
    `loon-launch` is not here: it lives in `github:loonbac/loon-launch` and reaches
    the system as a flake input.
  - `modules/`: Modular NixOS configuration categories (`system/`, `networking/`, `services/`, `wayland/`, `programs/`, `users/`).
  - `hosts/`: Per-host identity, hardware configurations, and platform overrides.

## Verification & Quality Tooling

- **Flake Evaluation**: `nix flake check --no-build` verifies all declared packages and host configurations evaluate cleanly without syntax or import errors.
- **Package Build Verification**: `nix build .#<package>` builds specific derivations under `pkgs/`.
- **System Build Verification**: `nixos-rebuild build --flake .#<host>` verifies end-to-end system generation.
- **Strict TDD**: Set to `false` in `openspec/config.yaml` as the repository uses declarative Nix evaluation and package builds rather than an automated unit-test runner.

## SDD Preflight Configuration

- `execution_mode`: auto
- `artifact_store`: openspec
- `delivery_strategy`: ask-on-risk
- `review_budget_lines`: 400
- `chain_strategy`: deferred
