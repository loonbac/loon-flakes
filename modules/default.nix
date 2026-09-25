# Módulo raíz: equivalente al `mod.rs` raíz del proyecto.
# Aquí se declaran TODOS los módulos del sistema. Para activar/desactivar
# un módulo completo, comenta su import (como un `mod foo;`).
{ config, lib, pkgs, ... }:

{
  imports = [
    ./system
    ./system/nix-ld.nix
    ./networking
    ./services
    ./programs
    ./wayland
    ./users
  ];

  # Una regla raw con saltos de línea genera varias órdenes tmpfiles y puede
  # romper el aprovisionamiento de un home nuevo. Para contenido multilínea,
  # declarar un archivo en /etc y copiarlo con una regla `C`.
  assertions = [
    {
      assertion = lib.all (rule: !(lib.hasInfix "\n" rule)) config.systemd.tmpfiles.rules;
      message = "systemd.tmpfiles.rules no admite reglas multilínea; usa un archivo en /etc y una regla C";
    }
  ];
}
