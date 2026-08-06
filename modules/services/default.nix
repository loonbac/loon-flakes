# Módulo "services": agregador de servicios del sistema.
# Como `core/ai/mod.rs` en loon-librust: un "mod" que compone sub-servicios.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./openssh
  ];
}
