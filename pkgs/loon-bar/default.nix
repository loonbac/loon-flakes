# Paquete "loon-bar": barra de tareas nativa Wayland para niri estilo Windows 10.
# Se compila con buildRustPackage usando el Cargo.lock del repo.
{ lib, rustPlatform, gtk4, glib, gtk4-layer-shell, pkg-config, wrapGAppsHook4, glib-networking, gobject-introspection }:

rustPlatform.buildRustPackage {
  pname = "loon-bar";
  version = "0.1.0";

  src = ./.;
  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  nativeBuildInputs = [ pkg-config wrapGAppsHook4 gobject-introspection ];
  buildInputs = [ gtk4 glib gtk4-layer-shell glib-networking ];

  meta = {
    description = "Barra de tareas nativa Wayland para Niri estilo Windows 10";
    license = lib.licenses.mit;
  };
}
