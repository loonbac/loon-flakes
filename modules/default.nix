# Módulo raíz: equivalente al `mod.rs` raíz del proyecto.
# Aquí se declaran TODOS los módulos del sistema. Para activar/desactivar
# un módulo completo, comenta su import (como un `mod foo;`).
{ config, lib, pkgs, ... }:

{
  imports = [
    ./system
    ./networking
    ./services
    ./programs
    ./wayland
    ./users
  ];
}
