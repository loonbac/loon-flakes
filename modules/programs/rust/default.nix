# Módulo "programs/rust": toolchain Rust del sistema, con el directorio de
# artefactos (`target/`) fuera del árbol de trabajo.
#
# El `cargo` del PATH es el wrapper de pkgs/cargo-target-cache: define
# CARGO_TARGET_DIR hacia `<cacheRoot>/<workspace>`, así un proyecto guardado en
# una partición chica almacena solo código. El caché vive en el disco raíz y
# `cargo clean` borra el del workspace invocado, no el de los demás.
#
# `rust-toolchain.toml` de los proyectos no interviene: sin rustup, el toolchain
# es el de nixpkgs y el wrapper no lo sustituye.
{ pkgs, ... }:

let
  cacheRoot = "/var/cache/rust-target";

  # El wrapper aporta `bin/cargo`; el cargo real y rustc entran como
  # runtimeInputs suyos, de modo que el PATH tiene un solo `cargo`.
  cargoTargetCache = pkgs.callPackage ../../../pkgs/cargo-target-cache {
    inherit cacheRoot;
  };
in
{
  environment.systemPackages = [
    cargoTargetCache
    pkgs.rustc
    pkgs.rustfmt # componente fmt (`cargo fmt`)
    pkgs.clippy # componente clippy (lints)
  ];

  # El wrapper compila como el usuario, así que el directorio raíz del caché
  # debe pertenecerle. Ruta absoluta: tmpfiles no expande `~`.
  systemd.tmpfiles.rules = [
    "d ${cacheRoot} 0755 loonbac users -"
  ];
}
