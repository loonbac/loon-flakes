# Tema Plymouth estilo macOS con el logo oficial de NixOS
# Combina la estética limpia de macOS (fondo negro, barra de progreso sutil)
# con el copo de nieve blanco de NixOS con canal alfa real (PNG32 / TrueColorAlpha).
{ lib, stdenv, fetchzip, nixos-icons, imagemagick }:

stdenv.mkDerivation {
  pname = "mac-plymouth";
  version = "1.0.0";

  src = fetchzip {
    url = "https://github.com/fathyar/mac-plymouth/archive/master.tar.gz";
    hash = "sha256-UP1OMHQv2Lft1GFHEhZflqg95uT5GW9dP7ktwz8koSA=";
  };

  nativeBuildInputs = [ imagemagick ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/plymouth/themes/mac"
    cp -r mac/* "$out/share/plymouth/themes/mac/"

    # Reemplaza el logo con el snowflake blanco oficial en formato PNG32 (RGBA con canal alfa)
    # para evitar que ImageMagick cree un archivo Grayscale/Bilevel de fondo opaco.
    magick "${nixos-icons}/share/icons/hicolor/512x512/apps/nix-snowflake-white.png" \
      -resize 150x150 -type TrueColorAlpha PNG32:"$out/share/plymouth/themes/mac/boot.png"

    # Enlaces de shutdown para que coincidan con el logo blanco
    for i in 1 2 3 4 5 6; do
      ln -sf boot.png "$out/share/plymouth/themes/mac/shutdown$i.png"
    done

    substituteInPlace "$out/share/plymouth/themes/mac/mac.plymouth" \
      --replace-fail "/usr/" "$out/"
    runHook postInstall
  '';

  meta = {
    description = "macOS-style Plymouth theme with NixOS Snowflake logo";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
