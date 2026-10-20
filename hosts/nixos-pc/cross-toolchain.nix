# Compilación cruzada armhf para la caja rk322x (proyecto ressy-tv).
# La caja armv7 no compila: el cruce se hace desde esta PC, así que el
# toolchain es una capacidad de este host y no del módulo compartido, que la
# laptop también importa y no lo usa (~364 MiB).
#
# `buildPackages` es la variante correcta: trae el wrapper con el targetPrefix
# del objetivo (`armv7l-unknown-linux-gnueabihf-`), más la glibc y libgcc del
# target. Los detalles del proyecto que no viven aquí (target de rustup,
# `.cargo/config.toml` y el ajuste de enlazado para binarios que correrán en la
# caja: `-Wl,--dynamic-linker=/lib/ld-linux-armhf.so.3`, porque el gcc del store
# embebe un INTERP de /nix/store y la caja usa glibc 2.35 frente a la 2.42 del
# store) están en el repo ressy-tv, `docs/toolchain.md`.
{ pkgs, ... }:

{
  environment.systemPackages = [
    pkgs.pkgsCross.armv7l-hf-multiplatform.buildPackages.gcc
  ];
}
