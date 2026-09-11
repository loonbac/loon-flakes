{ lib, stdenv, python3, cudaPackages, writeShellApplication, git, uv, ffmpeg, libsndfile, libsamplerate, pkg-config }:

writeShellApplication {
  name = "karaoke-separator";
  runtimeInputs = [ git uv ffmpeg libsndfile libsamplerate pkg-config ];
  runtimeEnv = {
    LD_LIBRARY_PATH = "/run/opengl-driver/lib:${lib.makeLibraryPath [ stdenv.cc.cc ]}";
    TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
    TRITON_PTXAS_PATH = "${cudaPackages.cuda_nvcc}/bin/ptxas";
    KARAOKE_PYTHON_INCLUDE_DIR = "${python3}/include/python${python3.pythonVersion}";
  };
  text = builtins.readFile ./karaoke-separator.sh;
}
