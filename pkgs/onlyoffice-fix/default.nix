# Fix ONLYOFFICE en Wayland puro (niri):
#   - El paquete nixpkgs fuerza QT_QPA_PLATFORM=xcb (su Qt embebido no
#     soporta Wayland) y muere con "Could not connect to any X display".
#   - xwayland-satellite (lanzado por niri) provee DISPLAY=:0 con socket
#     /tmp/.X11-unix/X0. El wrapper del paquete monta ese socket dentro del
#     sandbox FHS (bwrap) solo si DISPLAY tiene formato :N, así que basta
#     con exportar DISPLAY aquí (loon-launch lo hereda al lanzar).
{ pkgs, lib }:
pkgs.writeShellScriptBin "onlyoffice-desktopeditors" ''
  # X11 display provisto por xwayland-satellite (rootless, display :0).
  export DISPLAY=":0"
  exec ${pkgs.onlyoffice-desktopeditors}/bin/onlyoffice-desktopeditors "$@"
''
