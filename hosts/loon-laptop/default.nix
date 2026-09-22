# host "loon-laptop": como `src/main.rs` — solo compone,
# no define lógica. La lógica vive en ../modules.
#
# TODO: los drivers/firmware de este host están aquí abajo y NO en
# ../modules, porque son específicos del hardware de esta laptop
# (Dell Inspiron 15 3520). Otros hosts que usen este flake no deben
# heredarlos.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./platform.nix
    ./power.nix
  ];

  # Identidad del host (análogo al `[package] name` del Cargo.toml).
  networking.hostName = "loon-laptop";
  system.stateVersion = "26.05";

  # Bypass de Tailscale supervisado por túnel SSH/SOCKS5 exclusivo de la laptop.
  services.ts-bypass.enable = true;
}
