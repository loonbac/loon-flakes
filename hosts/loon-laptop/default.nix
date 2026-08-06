# host "loon-laptop": como `src/main.rs` — solo compone,
# no define lógica. La lógica vive en ../modules.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Identidad del host (análogo al `[package] name` del Cargo.toml).
  networking.hostName = "loon-laptop";
  system.stateVersion = "26.05";
}
