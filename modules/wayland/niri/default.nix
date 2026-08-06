# Módulo "wayland/niri": compositor Wayland niri (scrollable-tiling).
# Cada compositor/servicio en su propia carpeta, como un crate.
#
# El módulo de nixpkgs (programs.niri) lo instala y lo registra como
# sesión del display manager. La configuración fina (teclas, layout,
# barras, etc.) va en el archivo KDL del usuario:
#   ~/.config/niri/config.kdl   (ver https://niri.dev)
{ config, lib, pkgs, ... }:

{
  programs.niri = {
    enable = true;
  };
}
