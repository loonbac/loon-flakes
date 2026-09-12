{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  binutils,
  gnutar,
  gzip,
  obs-studio,
  curl,
  qt6,
  stdenv,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "obs-aitum-vertical";
  version = "1.6.4";

  src = fetchurl {
    url = "https://github.com/Aitum/obs-vertical-canvas/releases/download/${finalAttrs.version}/vertical-canvas-linux-gnu.deb";
    hash = "sha256-yYLWrPJI+D5+l9NUBV4kX6aVe2ZxX0JJuEnZEwQqrzc=";
  };

  dontUnpack = true;
  # Es una biblioteca que carga OBS, no una aplicación Qt independiente.
  dontWrapQtApps = true;
  nativeBuildInputs = [
    autoPatchelfHook
    binutils
    gnutar
    gzip
  ];
  buildInputs = [
    obs-studio
    curl
    qt6.qtbase
    stdenv.cc.cc
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    ar p "$src" data.tar.gz | tar -xzf - -C "$out" --strip-components=2
    chmod u+w "$out/lib/x86_64-linux-gnu/obs-plugins/vertical-canvas.so"
    mv "$out/lib/x86_64-linux-gnu/obs-plugins" "$out/lib/obs-plugins"
    rmdir "$out/lib/x86_64-linux-gnu"
    runHook postInstall
  '';

  meta = {
    description = "Aitum Vertical canvas plugin for OBS Studio";
    homepage = "https://github.com/Aitum/obs-vertical-canvas";
    license = lib.licenses.gpl2Only;
    inherit (obs-studio.meta) platforms;
  };
})
