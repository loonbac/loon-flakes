{ lib
, buildFHSEnv
, fetchFromGitHub
, libdrm
, libgbm
, libglvnd
, meson
, mesa
, ninja
, pipewire
, pkg-config
, requireFile
, stdenv
, stdenvNoCC
, unzip
}:

let
  version = "2.2";
  archiveName = "veadotube-mini-linux-x64.zip";

  # itch.io entrega enlaces de descarga temporales. El ZIP no se versiona ni se
  # descarga implícitamente: requireFile exige el release exacto por hash,
  # igual que el paquete propietario de Cisco Packet Tracer.
  unpacked = stdenvNoCC.mkDerivation {
    pname = "veadotube-mini-unpacked";
    inherit version;

    src = requireFile {
      name = archiveName;
      hash = "sha256-JHgC9nhMTr76zavmj8kzmdTyOwWFdSJ1lEpx26yAnrA=";
      url = "https://olmewe.itch.io/veadotube-mini";
      message = ''
        Add the exact Veadotube Mini ${version} Linux x64 ZIP to the Nix store first:

          nix store add --mode flat --hash-algo sha256 \
            --name ${archiveName} /path/to/${archiveName}
      '';
    };

    nativeBuildInputs = [ unzip ];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      install -d "$out"
      unzip -q "$src" -d "$out"
      chmod +x "$out/veadotube-mini" "$out/lib/input.sh" "$out/lib/ovrlipsync.sh"

      runHook postInstall
    '';
  };

  # Veadotube Mini 2.2 bundles an older libfunnel.  In an NVIDIA EGL context
  # that library can fail to obtain EGL's DRM-node attribute.  Build the
  # current compatible library with a small, opt-in fallback instead.
  funnel = stdenv.mkDerivation {
    pname = "libfunnel-veadotube";
    version = "2026-03-18";

    src = fetchFromGitHub {
      owner = "hoshinolina";
      repo = "libfunnel";
      rev = "779586dab6ad396ce4a363204c8b9a18f473ca5d";
      hash = "sha256-eBuWoE13PDWePSzxCNVFnuM0SRZ/HxzUtSgs0SFHu/c=";
    };

    patches = [ ./funnel-render-node-fallback.patch ];
    nativeBuildInputs = [ meson ninja pkg-config ];
    buildInputs = [ libdrm libgbm libglvnd mesa pipewire ];
    mesonFlags = [ "-Degl=true" "-Dvulkan=false" "-Dtest_apps=false" ];
  };

  runtime = stdenvNoCC.mkDerivation {
    pname = "veadotube-mini-runtime";
    inherit version;
    src = unpacked;

    installPhase = ''
      runHook preInstall

      cp -a "$src/." "$out"
      chmod -R u+w "$out"
      install -Dm755 ${funnel}/lib/libfunnel.so "$out/lib/libfunnel.so"
      install -Dm755 ${funnel}/lib/libfunnel-egl.so "$out/lib/libfunnel-egl.so"

      runHook postInstall
    '';
  };
in
buildFHSEnv {
  pname = "veadotube-mini";
  inherit version;

  # Veadotube is a precompiled SDL/.NET application. An FHS environment keeps
  # its bundled `lib/` layout intact while providing NixOS-compatible loaders,
  # graphics, audio, font and Wayland/X11 runtime libraries.
  targetPkgs = pkgs: with pkgs; [
    alsa-lib
    atk
    cairo
    dbus
    expat
    fontconfig
    freetype
    glib
    harfbuzz
    icu
    libdrm
    libGL
    libpulseaudio
    libx11
    libxcomposite
    libxdamage
    libxext
    libxi
    libxrandr
    libxscrnsaver
    libxcb
    libxkbcommon
    mesa
    nspr
    nss
    pango
    pipewire
    stdenv.cc.cc
    udev
    vulkan-loader
    wayland
    zlib
  ];

  extraBwrapArgs = [
    "--setenv FUNNEL_RENDER_NODE /dev/dri/renderD128"
    "--ro-bind ${runtime} /opt/veadotube-mini"
  ];
  runScript = "/opt/veadotube-mini/veadotube-mini";

  extraInstallCommands = ''
    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/veadotube-mini.desktop" <<'EOF'
    [Desktop Entry]
    Name=Veadotube Mini
    Comment=Lightweight PNGTuber application
    Exec=veadotube-mini
    Icon=applications-graphics
    Terminal=false
    Type=Application
    Categories=Graphics;
    Keywords=vtuber;pngtuber;streaming;avatar;
    StartupWMClass=veadotube-mini
    EOF
  '';

  meta = {
    description = "Lightweight PNGTuber application";
    homepage = "https://veado.tube/";
    license = lib.licenses.unfree;
    mainProgram = "veadotube-mini";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
