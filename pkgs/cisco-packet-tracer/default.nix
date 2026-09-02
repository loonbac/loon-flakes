{ lib
, buildFHSEnv
, dpkg
, requireFile
, stdenvNoCC
}:

let
  # Cisco's Linux installer is proprietary and cannot be committed to Git.
  # The flat SHA-256 below makes the external artifact deterministic once the
  # user has added that exact file to the local Nix store.
  version = "9.0.0-beta-build680";
  debName = "CiscoPacketTracer900_Open_Beta_July_Build680_linux_amd64_Exp20251231.deb";

  unpacked = stdenvNoCC.mkDerivation {
    pname = "cisco-packet-tracer-unpacked";
    inherit version;

    src = requireFile {
      name = debName;
      hash = "sha256-7PFhw16Y+GZJvb5gpq0jZRnCJagOrpHR8SRGjhTw/Xo=";
      url = "https://www.netacad.com/resources/lab-downloads";
      message = ''
        Add Cisco's exact Packet Tracer installer to the Nix store first:

          nix store add --mode flat --hash-algo sha256 \
            --name ${debName} /path/to/${debName}
      '';
    };

    nativeBuildInputs = [ dpkg ];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      dpkg-deb -x "$src" "$out"
      runHook postInstall
    '';
  };
in

buildFHSEnv {
  pname = "cisco-packet-tracer";
  inherit version;

  targetPkgs = pkgs: with pkgs; [
    alsa-lib
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    glib
    libdrm
    libGL
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
    wayland
    libxcb-cursor
    libxcb-image
    libxcb-keysyms
    libxcb-render-util
    libxcb-wm
    zlib
  ];

  # The Cisco launcher and Qt runtime use /opt/pt as an absolute path.
  extraBwrapArgs = [
    "--ro-bind ${unpacked}/opt/pt /opt/pt"
  ];
  runScript = "/opt/pt/packettracer";

  extraInstallCommands = ''
    ln -s "$out/bin/cisco-packet-tracer" "$out/bin/packettracer9"
    mkdir -p "$out/share/applications" "$out/share/icons/hicolor/48x48/apps"
    cat > "$out/share/applications/cisco-packet-tracer.desktop" <<'EOF'
    [Desktop Entry]
    Name=Cisco Packet Tracer
    Comment=Network simulation tool from Cisco
    Exec=packettracer9 %U
    Icon=cisco-packet-tracer
    Terminal=false
    Type=Application
    Categories=Education;Network;
    EOF
    cp "${unpacked}/opt/pt/art/app.png" \
      "$out/share/icons/hicolor/48x48/apps/cisco-packet-tracer.png"
  '';

  meta = {
    description = "Cisco Packet Tracer 9.0 beta (user-supplied proprietary installer)";
    homepage = "https://www.netacad.com/courses/packet-tracer";
    license = lib.licenses.unfree;
    mainProgram = "packettracer9";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
