# Módulo raíz: equivalente al `core/mod.rs` de loon-librust.
# Aquí se declaran TODOS los módulos del sistema. Para activar/desactivar
# un módulo completo, comenta su import (como un `mod foo;`).
{ config, lib, pkgs, ... }:

{
  imports = [
    ./system
    ./networking
    ./services
    ./users
  ];
}
