# Tema de cursor "Win11OSX" — tema Xcursor nativo de Linux (compatible con
# libxcursor: 187 cursores incluidos los nombres hash para apps antiguas).
# Se instala como share/icons/Win11OSX/ para que niri/libxcursor lo encuentre.
{ lib, stdenv }:

stdenv.mkDerivation {
  pname = "win11osx-cursor";
  version = "1.0.0";

  src = ./.;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/icons/Win11OSX"
    cp -r "$src/cursors" "$out/share/icons/Win11OSX/"
    cp "$src/index.theme" "$out/share/icons/Win11OSX/"
    runHook postInstall
  '';

  meta = {
    description = "Cursor Win11OSX (Xcursor nativo, estilo Windows 11 + macOS)";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
