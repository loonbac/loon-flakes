# omafiles: explorador de archivos nativo de Wayland, escrito en Rust sobre
# GPUI (el framework de Zed). No está en nixpkgs; este paquete lo construye
# desde el tag v0.0.9.
#
# Tres cosas lo hacen distinto de un empaquetado normal:
#
#  1. `gpui` y `gpui-component` llegan por git, no del registro de crates. Su
#     Cargo.toml avisa que `gpui` "flota a propósito" y que Cargo.lock es el
#     pin; el lock sí trae rev fijo (zed#a66fb6ae), así que `importCargoLock`
#     puede reproducirlo sin vendorizar a mano.
#  2. GPUI necesita Vulkan y Wayland en tiempo de enlace: vulkan-loader,
#     wayland, libxkbcommon y fontconfig.
#  3. El binario se llama `omafiles` y su app_id es `dev.omarchy.omafiles`;
#     el .desktop tiene que llevar ese mismo nombre de fichero o Wayland no
#     asocia la ventana con la entrada.
#
# El tema: la app lee los tokens de Omarchy desde
# `~/.local/state/omarchy/current/theme/colors.toml` y, cuando no existe,
# cae a un `fallback-theme.toml` neutro embebido. En NixOS ese directorio no
# existe, así que arranca con el tema de respaldo. Ver AGENTS.md.
{ lib
, rustPlatform
, fetchFromGitHub
, pkg-config
, clang
, cmake
, makeWrapper
, fontconfig
, freetype
, libxkbcommon
, libxcb
, wayland
, vulkan-headers
, vulkan-loader
, stdenv
, git
, ffmpeg
, xdg-utils
, glib
, wl-clipboard
}:

rustPlatform.buildRustPackage rec {
  pname = "omafiles";
  version = "0.0.9";

  src = fetchFromGitHub {
    owner = "aloisdeniel";
    repo = "omafiles";
    rev = "v${version}";
    hash = "sha256-oWYDTSKy6YOSWZavyEq4Jent9XsZhwyQ2vPdxa+LKhs=";
  };

  cargoLock = {
    # El lock viene del propio fuente: fija gpui (zed#a66fb6ae) y
    # gpui-component (rev 5cb0946) por rev exacto, que es el pin que el
    # proyecto delega al lockfile a propósito.
    lockFile = "${src}/Cargo.lock";
    outputHashes = {
      "collections-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "derive_refineable-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui-0.2.2" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui-base-0.5.2" = "sha256-jfO8ICjht89zNRTcVINSkqldLTKDBQ/f5RLaq76sIhw=";
      "gpui-component-0.5.2" = "sha256-jfO8ICjht89zNRTcVINSkqldLTKDBQ/f5RLaq76sIhw=";
      "gpui-component-assets-0.5.1" = "sha256-jfO8ICjht89zNRTcVINSkqldLTKDBQ/f5RLaq76sIhw=";
      "gpui-component-macros-0.5.1" = "sha256-jfO8ICjht89zNRTcVINSkqldLTKDBQ/f5RLaq76sIhw=";
      "gpui_apple-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_linux-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_macos-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_macros-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_platform-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_shared_string-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_util-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_web-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_wgpu-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "gpui_windows-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "http_client-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "media-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "perf-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "refineable-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "scheduler-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "sum_tree-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "util_macros-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "wasm_thread-0.3.3" = "sha256-+lRLCIk0S6Y5ORYjDKsYYHia2FtoSoh+rWkQh7mnPBE=";
      "xim-ctext-0.3.0" = "sha256-pRT4Sz1JU9ros47/7pmIW9kosWOGMOItcnNd+VrvnpE=";
      "xim-parser-0.2.1" = "sha256-pRT4Sz1JU9ros47/7pmIW9kosWOGMOItcnNd+VrvnpE=";
      "zed-font-kit-0.14.1-zed" = "sha256-KXygi0olNQi5yM8eaJVykNDtbPMDjT+cWPBF8UrtXR4=";
      "zed-reqwest-0.12.15-zed" = "sha256-p4SiUrOrbTlk/3bBrzN/mq/t+1Gzy2ot4nso6w6S+F8=";
      "zed-scap-0.0.8-zed" = "sha256-BihiQHlal/eRsktyf0GI3aSWsUCW7WcICMsC2Xvb7kw=";
      "zed-xim-0.4.0-zed" = "sha256-pRT4Sz1JU9ros47/7pmIW9kosWOGMOItcnNd+VrvnpE=";
      "zlog-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "ztracing-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
      "ztracing_macro-0.1.0" = "sha256-UAho7Cv/oRTUX5jtXT6GW7BMwHuugVQ1tokM6RDiGrM=";
    };
  };

  nativeBuildInputs = [
    pkg-config
    clang
    cmake
    makeWrapper
  ];

  buildInputs = [
    fontconfig
    freetype
    libxkbcommon
    libxcb
    wayland
    vulkan-headers
    vulkan-loader
    stdenv.cc.cc.lib
    glib
  ];

  # El workspace tiene tres crates y solo `omafiles` produce el binario.
  cargoBuildFlags = [ "-p" "omafiles" ];

  # Los crates de Zed enlazan C (tree-sitter) con clang/lld.
  env = {
    LIBCLANG_PATH = "${clang.cc.lib}/lib";
    RUSTFLAGS = lib.concatStringsSep " " [
      "-C link-arg=-Wl,-rpath,${vulkan-loader}/lib"
    ];
  };

  # El binario invoca git, ffmpeg y xdg-open (y wl-copy para el portapapeles).
  # No los necesita para compilar, solo en ejecución, así que van al wrapper y
  # no a buildInputs.
  postInstall = ''
    mkdir -p $out/share/applications
    install -Dm644 contrib/omafiles.desktop \
      $out/share/applications/dev.omarchy.omafiles.desktop
  '';

  postFixup = ''
    wrapProgram $out/bin/omafiles \
      --prefix PATH : ${lib.makeBinPath [ git ffmpeg xdg-utils wl-clipboard ]} \
      --set-default GDK_BACKEND wayland
  '';

  meta = {
    description = "Keyboard-first file explorer for Omarchy";
    homepage = "https://github.com/aloisdeniel/omafiles";
    license = lib.licenses.mit;
    mainProgram = "omafiles";
    platforms = [ "x86_64-linux" ];
    # gpui es un framework inestable de Zed; el lock lo fija.
    broken = false;
  };
}
