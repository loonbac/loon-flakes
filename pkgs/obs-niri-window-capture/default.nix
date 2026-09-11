{
  lib,
  stdenv,
  meson,
  ninja,
  pkg-config,
  obs-studio,
  glib,
  niri,
}:

stdenv.mkDerivation {
  pname = "obs-niri-window-capture";
  version = "0.2.0";

  src = ./.;

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];

  postPatch = ''
    substituteInPlace niri-window-capture.c \
      --replace-fail '@niriBin@' '${lib.getExe niri}'
  '';

  buildInputs = [
    obs-studio
    glib
  ];

  meta = {
    description = "Persistent application capture for OBS through niri's dynamic cast target";
    homepage = "https://github.com/niri-wm/niri/wiki/Screencasting";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
