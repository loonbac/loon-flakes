# Paquete "loon-launch": app launcher Wayland para niri.
# Lista apps (.desktop) y acciones de poder con prefijo '>'.
# Se compila con buildRustPackage usando el Cargo.lock del repo.
{ lib, rustPlatform, gtk4, glib, libadwaita, pkg-config, wrapGAppsHook4, glib-networking, gobject-introspection }:

rustPlatform.buildRustPackage {
  pname = "loon-launch";
  version = "0.1.0";

  src = ./.;
  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  nativeBuildInputs = [ pkg-config wrapGAppsHook4 gobject-introspection ];
  buildInputs = [ gtk4 glib libadwaita glib-networking ];

  meta = {
    description = "App launcher Wayland para niri: apps + acciones de poder con prefijo '>'";
    license = lib.licenses.mit;
  };
}
