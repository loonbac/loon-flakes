{ lib
, stdenv
, fetchFromGitHub
, cmake
, ninja
, obs-studio
, pipewire
, libdrm
, libGL
, pkg-config
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "obs-pwvideo";
  version = "0.2.4";

  src = fetchFromGitHub {
    owner = "hoshinolina";
    repo = "obs-pwvideo";
    rev = "f992e85abea95dfc58e064a47514ae0e433965be";
    hash = "sha256-CCzeK5JyCWnIcty5xaDV5uCxvrMVx50f8SoLZnlF658=";
  };

  nativeBuildInputs = [ cmake ninja pkg-config ];
  buildInputs = [ obs-studio pipewire libdrm libGL.dev ];

  # Keep the layout expected by pkgs.wrapOBS: the plugin binary and data live
  # under lib/obs-plugins and share/obs/obs-plugins, respectively.
  cmakeFlags = [
    "-DCMAKE_INSTALL_LIBDIR=lib"
    "-DCMAKE_INSTALL_DATAROOTDIR=share"
  ];

  meta = {
    description = "Generic PipeWire video source for OBS Studio";
    homepage = "https://github.com/hoshinolina/obs-pwvideo";
    license = lib.licenses.gpl2Only;
    inherit (obs-studio.meta) platforms;
  };
})
