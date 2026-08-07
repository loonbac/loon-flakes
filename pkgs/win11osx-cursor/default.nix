# Tema de cursor "Win11OSX" — tema Xcursor nativo de Linux (compatible con
# libxcursor: 187 cursores incluidos los nombres hash para apps antiguas).
#
# Genera DOS temas:
#   - Win11OSX:      el tema normal (estático).
#   - Win11OSX-Grow: igual, pero default/left_ptr/arrow/top_left_arrow usan
#                    un cursor ANIMADO (12 frames que crecen de 32 a 64px)
#                    para el shake-to-find (niri-shake-cursor alterna el
#                    xcursor-theme entre ambos).
{ lib, stdenv }:

stdenv.mkDerivation {
  pname = "win11osx-cursor";
  version = "1.0.0";

  src = ./.;

  installPhase = ''
    runHook preInstall

    # Tema normal.
    mkdir -p "$out/share/icons/Win11OSX"
    cp -r "$src/cursors" "$out/share/icons/Win11OSX/"
    cp "$src/index.theme" "$out/share/icons/Win11OSX/"

    # Tema grow (animado): copia del normal, reemplazando los cursores
    # principales por el animado.
    mkdir -p "$out/share/icons/Win11OSX-Grow"
    cp -r "$src/cursors" "$out/share/icons/Win11OSX-Grow/"
    cp "$src/index.theme" "$out/share/icons/Win11OSX-Grow/"
    for c in default left_ptr arrow top_left_arrow context-menu; do
      chmod u+w "$out/share/icons/Win11OSX-Grow/cursors/$c"
      cp "$src/grow.cursor" "$out/share/icons/Win11OSX-Grow/cursors/$c"
    done
    # index.theme del grow con su nombre.
    sed -i 's/^Name=.*/Name=Win11OSX-Grow/' "$out/share/icons/Win11OSX-Grow/index.theme"

    runHook postInstall
  '';

  meta = {
    description = "Cursor Win11OSX (Xcursor nativo) + variante animada para shake-to-find";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
