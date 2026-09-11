{ lib, stdenv, writeShellApplication, git, uv, ffmpeg, libsndfile, libsamplerate, pkg-config }:

writeShellApplication {
  name = "karaoke-separator";
  runtimeInputs = [ git uv ffmpeg libsndfile libsamplerate pkg-config ];
  runtimeEnv.LD_LIBRARY_PATH = "/run/opengl-driver/lib:${lib.makeLibraryPath [ stdenv.cc.cc ]}";
  text = builtins.readFile ./karaoke-separator.sh;
}
