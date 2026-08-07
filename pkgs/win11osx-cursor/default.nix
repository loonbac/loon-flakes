# Tema de cursor "Win11OSX" — tema Xcursor nativo de Linux (compatible con
# libxcursor: 187 cursores incluidos los nombres hash para apps antiguas).
#
# Genera TRES temas:
#   - Win11OSX:      el tema normal (estático 32px).
#   - Win11OSX-Grow: igual, pero default/left_ptr/arrow/top_left_arrow usan
#                    un cursor ANIMADO (12 frames que crecen de 32 a 64px).
#                    Se reproduce UNA vez al detectar el shake.
#   - Win11OSX-Big:  igual, pero con el cursor ESTÁTICO de 64px (se queda
#                    grande mientras dura el efecto).
# niri-shake-cursor alterna: normal -> grow (animación) -> big (se queda) -> normal.
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

    # Tema grow (animado).
    mkdir -p "$out/share/icons/Win11OSX-Grow"
    cp -r "$src/cursors" "$out/share/icons/Win11OSX-Grow/"
    cp "$src/index.theme" "$out/share/icons/Win11OSX-Grow/"
    for c in default left_ptr arrow top_left_arrow context-menu; do
      chmod u+w "$out/share/icons/Win11OSX-Grow/cursors/$c"
      cp "$src/grow.cursor" "$out/share/icons/Win11OSX-Grow/cursors/$c"
    done
    sed -i 's/^Name=.*/Name=Win11OSX-Grow/' "$out/share/icons/Win11OSX-Grow/index.theme"

    # Tema big (estático grande).
    mkdir -p "$out/share/icons/Win11OSX-Big"
    cp -r "$src/cursors" "$out/share/icons/Win11OSX-Big/"
    cp "$src/index.theme" "$out/share/icons/Win11OSX-Big/"
    for c in default left_ptr arrow top_left_arrow context-menu; do
      chmod u+w "$out/share/icons/Win11OSX-Big/cursors/$c"
      cp "$src/big.cursor" "$out/share/icons/Win11OSX-Big/cursors/$c"
    done
    sed -i 's/^Name=.*/Name=Win11OSX-Big/' "$out/share/icons/Win11OSX-Big/index.theme"

    runHook postInstall
  '';

  meta = {
    description = "Cursor Win11OSX (Xcursor nativo) + variantes grow/big para shake-to-find";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
