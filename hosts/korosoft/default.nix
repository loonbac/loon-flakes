# host "korosoft": como `src/main.rs` de loon-librust — solo compone,
# no define lógica. La lógica vive en ../modules.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Identidad del host (análogo al `[package] name` del Cargo.toml).
  networking.hostName = "korosoft";
  system.stateVersion = "26.05";
}
