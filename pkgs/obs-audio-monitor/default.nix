{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  obs-studio,
  qt6,
  libpulseaudio,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "obs-audio-monitor";
  version = "0.10.1";

  src = fetchFromGitHub {
    owner = "exeldro";
    repo = "obs-audio-monitor";
    tag = finalAttrs.version;
    hash = "sha256-FbKhppwYomGDmp6ZNqiy+iNwSioG+ZO8g2VRxjS8AhY=";
  };

  nativeBuildInputs = [ cmake ];
  buildInputs = [
    obs-studio
    qt6.qtbase
    libpulseaudio
  ];

  # 0.10.1 enlaza Qt::GuiPrivate sin importar antes su configuración CMake.
  # Nix no carga targets privados implícitamente, así que lo hacemos explícito.
  postPatch = ''
    substituteInPlace CMakeLists.txt \
      --replace-fail \
        'target_link_libraries(''${PROJECT_NAME} PRIVATE Qt::GuiPrivate)' \
        $'find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)\n\ttarget_link_libraries(''${PROJECT_NAME} PRIVATE Qt::GuiPrivate)'
  '';

  cmakeFlags = [
    "-DBUILD_OUT_OF_TREE=On"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    "-DCMAKE_INSTALL_DATAROOTDIR=share"
  ];

  # OBS aporta el runtime Qt; envolver el .so como una aplicación es incorrecto.
  dontWrapQtApps = true;

  meta = {
    description = "Audio monitoring plugin for OBS Studio";
    homepage = "https://github.com/exeldro/obs-audio-monitor";
    license = lib.licenses.gpl2Only;
    inherit (obs-studio.meta) platforms;
  };
})
