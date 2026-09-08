# Project Context: loon-flakes

Initialized: 2026-09-08
Artifact Store: openspec
Workspace Root: /home/loonbac/.nixos

## Architecture & Stack Overview

- **Stack**: NixOS multi-host configuration (Nixpkgs 26.05) managed with Nix Flakes.
- **Hosts**:
  - `loon-laptop`: Dell XPS laptop (Intel iHD/i915 graphics, dedicated AC/battery power management).
  - `nixos-pc`: AMD Ryzen 7 5700X desktop with NVIDIA GPU.
  - `korosoft`: Secondary configuration profile.
- **Repository Structure**:
  - `flake.nix` & `flake.lock`: Entrypoint flake declaring inputs, outputs, packages, and NixOS configurations.
  - `pkgs/`: Custom derivation packages (`rebuild`, `loon-launch`, `steamidra`, `vision-cursor`, etc.).
  - `modules/`: Modular NixOS configuration categories (`system/`, `networking/`, `services/`, `wayland/`, `programs/`, `users/`).
  - `hosts/`: Per-host identity, hardware configurations, and platform overrides.

## Verification & Quality Tooling

- **Flake Evaluation**: `nix flake check --no-build` verifies all declared packages and host configurations evaluate cleanly without syntax or import errors.
- **Package Build Verification**: `nix build .#<package>` builds specific derivations under `pkgs/`.
- **System Build Verification**: `nixos-rebuild build --flake .#<host>` verifies end-to-end system generation.
- **Strict TDD**: Set to `false` in `openspec/config.yaml` as the repository uses declarative Nix evaluation and package builds rather than an automated unit-test runner.

## Active SDD Scope & Boundary Guardrails

- **Scope**: Create a standalone, externally consumable NixOS module and package interface for SteaMidra (Midrags/SFF).
- **Deliverables**:
  1. A pinned `x86_64-linux` package derivation for SteaMidra.
  2. An opt-in NixOS module interface (with configurable options) without hard-coded usernames, home directories, or host hardware assumptions.
- **Non-Goals / Exclusions**:
  - Do NOT refactor the rest of the personal NixOS configuration.
  - Do NOT modify unrelated users, hardware profiles, hosts, or unrelated modules.
  - Keep changes strictly focused on the SteaMidra package and module surface.

## SDD Preflight Configuration

- `execution_mode`: auto
- `artifact_store`: openspec
- `delivery_strategy`: ask-on-risk
- `review_budget_lines`: 400
- `chain_strategy`: deferred
