# Tema de cursor "Vision Cursor" (variantes blanca y negra) para Wayland/X11.
# Empaca los PNGs del pack original como temas Xcursor generados con
# xcursorgen, usando los hotspots extraídos de los .cur/.ani de Windows.
# Tema blanco: Vision-White (por defecto). Tema negro: Vision-Black.
{ lib, stdenv, xcursorgen, imagemagick }:

let
  # ruta de un PNG dentro de una variante (White/Black)
  png = variant: name: "${./.}/${variant}/${name}";

  # hotspots originales (del .cur/.ani)
  hs = {
    pointer = "2 2";           # pointer.cur
    help = "2 2";              # help.cur
    link = "7 2";              # link.cur
    alternate = "16 2";        # alternate.cur
    move = "16 16";            # move.cur
    text = "16 16";            # text.cur
    cross = "16 16";           # cross.cur
    unavailiable = "2 2";      # unavailiable.cur
    horz = "16 16";            # horz.cur
    vert = "16 16";            # vert.cur
    dgnl = "16 16";            # dgn1.cur
    dgnr = "16 16";            # dgn2.cur
    handwriting = "2 2";       # handwriting.cur
    person = "7 2";            # person.cur
    pin = "7 2";               # pin.cur
    busy = "32 32";            # busy.ani
    work = "4 4";              # work.ani
  };

  # cursor-x11 -> png base (los PNG son de 32x32; busy/work de 64x64)
  basePng = variant: name: png variant name;

  # Lista de cursores estáticos: nombre x11, png base, tipo de hotspot.
  staticCursors = variant: [
    { name = "default";        png = "Pointer/pointer32.png";     hs = "pointer"; }
    { name = "left_ptr";       png = "Pointer/pointer32.png";     hs = "pointer"; }
    { name = "arrow";          png = "Pointer/pointer32.png";     hs = "pointer"; }
    { name = "top_left_arrow"; png = "Pointer/pointer32.png";     hs = "pointer"; }
    { name = "context-menu";   png = "Pointer/pointer32.png";     hs = "pointer"; }
    { name = "help";           png = "Help/help32.png";           hs = "help"; }
    { name = "whats_this";     png = "Help/help32.png";           hs = "help"; }
    { name = "hand";           png = "Link/link32.png";           hs = "link"; }
    { name = "hand1";          png = "Link/link32.png";           hs = "link"; }
    { name = "hand2";          png = "Link/link32.png";           hs = "link"; }
    { name = "grab";           png = "Move/move32.png";           hs = "move"; }
    { name = "grabbing";       png = "Move/move32.png";           hs = "move"; }
    { name = "all-scroll";     png = "Move/move32.png";           hs = "move"; }
    { name = "move";           png = "Move/move32.png";           hs = "move"; }
    { name = "fleur";          png = "Move/move32.png";           hs = "move"; }
    { name = "text";           png = "Text/text32.png";           hs = "text"; }
    { name = "xterm";          png = "Text/text32.png";           hs = "text"; }
    { name = "vertical-text";  png = "Text/text32.png";           hs = "text"; }
    { name = "crosshair";      png = "Cross/cross32.png";         hs = "cross"; }
    { name = "cross";          png = "Cross/cross32.png";         hs = "cross"; }
    { name = "cell";           png = "Cross/cross32.png";         hs = "cross"; }
    { name = "plus";           png = "Cross/cross32.png";         hs = "cross"; }
    { name = "copy";           png = "Pointer/pointer32.png";     hs = "alternate"; }
    { name = "alias";          png = "Pointer/pointer32.png";     hs = "alternate"; }
    { name = "link";           png = "Pointer/pointer32.png";     hs = "alternate"; }
    { name = "no-drop";        png = "Unavailiable/unavailiable32.png"; hs = "unavailiable"; }
    { name = "not-allowed";    png = "Unavailiable/unavailiable32.png"; hs = "unavailiable"; }
    { name = "forbidden";      png = "Unavailiable/unavailiable32.png"; hs = "unavailiable"; }
    { name = "dnd-no-drop";    png = "Unavailiable/unavailiable32.png"; hs = "unavailiable"; }
    { name = "dnd-move";       png = "Move/move32.png";           hs = "move"; }
    { name = "dnd-copy";       png = "Pointer/pointer32.png";     hs = "alternate"; }
    { name = "dnd-link";       png = "Pointer/pointer32.png";     hs = "alternate"; }
    { name = "dnd-ask";        png = "Help/help32.png";           hs = "help"; }
    { name = "col-resize";     png = "Horz/horz32.png";           hs = "horz"; }
    { name = "ew-resize";      png = "Horz/horz32.png";           hs = "horz"; }
    { name = "e-resize";       png = "Horz/horz32.png";           hs = "horz"; }
    { name = "w-resize";       png = "Horz/horz32.png";           hs = "horz"; }
    { name = "row-resize";     png = "Vert/vert32.png";           hs = "vert"; }
    { name = "ns-resize";      png = "Vert/vert32.png";           hs = "vert"; }
    { name = "n-resize";       png = "Vert/vert32.png";           hs = "vert"; }
    { name = "s-resize";       png = "Vert/vert32.png";           hs = "vert"; }
    { name = "ne-resize";      png = "Dgnl/dgnl32.png";           hs = "dgnl"; }
    { name = "sw-resize";      png = "Dgnl/dgnl32.png";           hs = "dgnl"; }
    { name = "nesw-resize";    png = "Dgnl/dgnl32.png";           hs = "dgnl"; }
    { name = "nwse-resize";    png = "Dgnr/dgnr32.png";           hs = "dgnr"; }
    { name = "nw-resize";      png = "Dgnr/dgnr32.png";           hs = "dgnr"; }
    { name = "se-resize";      png = "Dgnr/dgnr32.png";           hs = "dgnr"; }
    { name = "up-arrow";       png = "Person/person32.png";       hs = "person"; }
    { name = "down-arrow";     png = "Person/person32.png";       hs = "person"; }
    { name = "left-arrow";     png = "Person/person32.png";       hs = "person"; }
    { name = "right-arrow";    png = "Person/person32.png";       hs = "person"; }
    { name = "pencil";         png = "Handwriting/handwriting32.png"; hs = "handwriting"; }
    { name = "circle";         png = "Cross/cross32.png";         hs = "cross"; }
    { name = "diamond-cross";  png = "Cross/cross32.png";         hs = "cross"; }
    { name = "target";         png = "Cross/cross32.png";         hs = "cross"; }
    { name = "pirate";         png = "Cross/cross32.png";         hs = "cross"; }
    { name = "sb_h_double_arrow"; png = "Horz/horz32.png";        hs = "horz"; }
    { name = "sb_v_double_arrow"; png = "Vert/vert32.png";        hs = "vert"; }
    { name = "size_all";       png = "Move/move32.png";           hs = "move"; }
    { name = "size_bdiag";     png = "Dgnl/dgnl32.png";           hs = "dgnl"; }
    { name = "size_fdiag";     png = "Dgnr/dgnr32.png";           hs = "dgnr"; }
    { name = "size_hor";       png = "Horz/horz32.png";           hs = "horz"; }
    { name = "size_ver";       png = "Vert/vert32.png";           hs = "vert"; }
    { name = "pointer";        png = "Pointer/pointer32.png";     hs = "pointer"; }
  ];

  # Cursores animados: nombre x11, lista de pngs (frames), hotspot, delay (ms).
  animatedCursors = variant: [
    { name = "progress"; frames = map (n: "Busy/${toString n}.png") (lib.range 1 12); hs = "busy"; delay = 120; }
    { name = "wait";     frames = map (n: "Busy/${toString n}.png") (lib.range 1 12); hs = "busy"; delay = 120; }
    { name = "watch";    frames = map (n: "Busy/${toString n}.png") (lib.range 1 12); hs = "busy"; delay = 120; }
    { name = "working";  frames = map (n: "Busy/${toString n}.png") (lib.range 1 12); hs = "busy"; delay = 120; }
    { name = "work";     frames = map (n: "Work/${toString n}.png") (lib.range 1 12); hs = "work"; delay = 120; }
  ];

  # Tamaños a generar (niri pide 24 por defecto; HiDPI puede pedir más).
  # El PNG base es de 32x32 (o 64x64 animado); se escala al tamaño pedido.
  sizes = [ 24 32 48 64 96 128 ];

  # Genera un tema Xcursor completo para una variante.
  buildTheme = { variant, themeName }: stdenv.mkDerivation {
    pname = "vision-cursor-${themeName}";
    version = "1.0.0";
    src = ./.;
    nativeBuildInputs = [ xcursorgen imagemagick ];
    inherit themeName variant;

    buildPhase = ''
      runHook preBuild
      mkdir -p "$out/cursors"

      # Genera un cursor desde un png base escalado a cada tamaño.
      # $1 = nombre x11, $2 = png base, $3 = hotspot X base, $4 = hotspot Y base,
      # $5 = delay (opcional, ""=estático)
      gen() {
        name="$1"; base="$2"; hsx="$3"; hsy="$4"; delay="$5"
        cfg=cfg.cursor
        rm -f "$cfg"
        for size in ${builtins.concatStringsSep " " (map toString sizes)}; do
          # Escala el png al tamaño pedido (mantiene aspect ratio).
          tmp="/tmp/gen-''${size}.png"
          magick "$base" -resize "''${size}x''${size}" "$tmp"
          # Hotspot proporcional al tamaño (base definido para 32px).
          hx=$(( hsx * size / 32 ))
          hy=$(( hsy * size / 32 ))
          if [ -n "$delay" ]; then
            printf '%s %s %s %s %s\n' "$size" "$hx" "$hy" "$tmp" "$delay" >> "$cfg"
          else
            printf '%s %s %s %s\n' "$size" "$hx" "$hy" "$tmp" >> "$cfg"
          fi
        done
        xcursorgen "$cfg" "$out/cursors/$name"
      }

      # Estáticos
      ${lib.concatMapStringsSep "\n" (c: ''
        gen "${c.name}" "${png variant c.png}" ${toString (builtins.head (lib.splitString " " (hs.${c.hs})))} ${toString (builtins.elemAt (lib.splitString " " (hs.${c.hs})) 1)} ""
      '') (staticCursors variant)}

      # Animados (frame 1 con delay, resto sin delay)
      ${lib.concatMapStringsSep "\n" (a: ''
        name="${a.name}"
        cfg=cfg.cursor
        rm -f "$cfg"
        for size in ${builtins.concatStringsSep " " (map toString sizes)}; do
          hx=$(( ${toString (builtins.head (lib.splitString " " (hs.${a.hs})))} * size / 32 ))
          hy=$(( ${toString (builtins.elemAt (lib.splitString " " (hs.${a.hs})) 1)} * size / 32 ))
          first=1
          for f in ${builtins.concatStringsSep " " (map (p: "${png variant p}") a.frames)}; do
            tmp="/tmp/an-''${size}.png"
            magick "$f" -resize "''${size}x''${size}" "$tmp"
            if [ "$first" = "1" ]; then
              printf '%s %s %s %s %s\n' "$size" "$hx" "$hy" "$tmp" ${toString a.delay} >> "$cfg"
              first=0
            else
              printf '%s %s %s %s\n' "$size" "$hx" "$hy" "$tmp" >> "$cfg"
            fi
          done
        done
        xcursorgen "$cfg" "$out/cursors/$name"
      '') (animatedCursors variant)}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      # Layout estándar de tema Xcursor: share/icons/<theme>/{cursors,index.theme}
      mkdir -p "$out/share/icons/${themeName}"
      mv "$out/cursors" "$out/share/icons/${themeName}/"
      cat > "$out/share/icons/${themeName}/index.theme" <<EOF
[Icon Theme]
Name=${themeName}
Comment=Vision Cursor theme (${variant})
EOF
      runHook postInstall
    '';
  };
in
{
  # Tema blanco (por defecto).
  white = buildTheme { variant = "White"; themeName = "Vision-White"; };
  # Tema negro.
  black = buildTheme { variant = "Black"; themeName = "Vision-Black"; };
}
