# SteaMidra (SFF) — Steam game setup and manifest tool.
#
# Distribuido como AppImage autocontenido (PyInstaller + PyQt6/QtWebEngine).
# En NixOS el runtime estándar de AppImage no corre (stub-ld), así que:
#   1. descargamos el zip de release oficial (contiene el .AppImage)
#   2. extraemos el .AppImage del zip
#   3. extraemos el payload con appimageTools.extract (squashfsTools, offset type-2)
#   4. envolvemos el payload en un buildFHSEnv con las libs de sistema que
#      PyInstaller NO embebe (nss, nspr, xcb, X11, alsa, GL, xkbcommon...)
#   5. bin/steamidra → entra al FHS y ejecuta el AppRun original (que setea
#      QT_PLUGIN_PATH y QTWEBENGINE_DISABLE_SANDBOX=1)
{ lib, fetchurl, unzip, appimageTools, buildFHSEnv, stdenv, writeShellScript,
  nss, nspr, zlib, alsa-lib, libxcb, libxkbcommon, libxkbfile, libGL, libx11,
  gtk3, glib, fontconfig, freetype, dbus, libdrm, mesa, wayland, libgpg-error, gnutls,
  xkeyboard-config }:

let
  version = "6.6.6";

  # 1) zip oficial de release (AppImage + instalador + icono)
  zip = fetchurl {
    url = "https://github.com/Midrags/SFF/releases/download/v${version}/SteaMidra-${version}-linux.zip";
    sha256 = "055f4a5d4775699e1dd87b57369d6ce8a29a2af04bf850583644da7a540b496f";
  };

  # 2) extraer el .AppImage (nombre variable SteaMidra-*-x86_64.AppImage)
  appimage = stdenv.mkDerivation {
    pname = "steamidra-appimage";
    inherit version;
    src = zip;
    nativeBuildInputs = [ unzip ];
    buildCommand = ''
      unzip -q "$src" '*.AppImage'
      install -Dm755 SteaMidra-*-x86_64.AppImage "$out"
    '';
  };

  # 3) payload descomprimido (contenido del squashfs: AppRun, usr/bin/SteaMidra_GUI, ...)
  payload = appimageTools.extract {
    pname = "steamidra-payload";
    inherit version;
    src = appimage;
  };

  # The release AppRun points Qt at usr/bin/PyQt6, but its PyInstaller bundle
  # places plugins and shared objects in usr/bin/_internal. Use the real paths
  # and force the known-good XWayland backend: the native Qt Wayland path
  # segfaults under niri for this bundled Qt 6.10 build.
  launch = writeShellScript "steamidra-payload" ''
    here="${payload}"
    export PATH="$here/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$here/usr/bin/_internal:$here/usr/bin:$LD_LIBRARY_PATH"
    export QT_PLUGIN_PATH="$here/usr/bin/_internal/PyQt6/Qt6/plugins"
    export QT_QPA_PLATFORM_PLUGIN_PATH="$here/usr/bin/_internal/PyQt6/Qt6/plugins/platforms"
    export QTWEBENGINE_DISABLE_SANDBOX=1
    export QT_QPA_PLATFORM=xcb
    exec "$here/usr/bin/SteaMidra_GUI" "$@"
  '';

  # 4) FHS env con las libs de sistema que el bundle no lleva.
  #    Nota: la app escribe settings.bin/logs/cache junto al path de la env
  #    APPIMAGE (ver sff/core/utils.py → root_folder), así que el wrapper
  #    apunta APPIMAGE a ~/.local/share/SteaMidra, como el instalador oficial.
  fhs = buildFHSEnv {
    name = "steamidra-fhs";

    targetPkgs = pkgs: with pkgs; [
      nss
      nspr
      zlib
      alsa-lib
      libxcb
      libxkbcommon
      libxkbfile
      xkeyboard-config
      libGL
      libx11
      gtk3
      glib
      fontconfig
      freetype
      dbus
      libdrm
      mesa
      wayland
      libgpg-error
      gnutls
    ];

    multiPkgs = pkgs: [ ];

    runScript = "${launch}";
  };

in
stdenv.mkDerivation {
  pname = "steamidra";
  inherit version;

  nativeBuildInputs = [ ];

  buildCommand = ''
    mkdir -p $out/bin $out/share/applications $out/share/icons/hicolor/256x256/apps
    cat > $out/bin/steamidra <<EOF
    #!/usr/bin/env bash
    # La app guarda settings.bin, logs y cache junto al path de APPIMAGE;
    # lo apuntamos a un dir escribible del usuario (como el instalador oficial).
    mkdir -p "\''${HOME}/.local/share/SteaMidra"
    export APPIMAGE="\''${HOME}/.local/share/SteaMidra/SteaMidra.AppImage"
    exec ${fhs}/bin/steamidra-fhs "\$@"
    EOF
    chmod +x $out/bin/steamidra

    install -Dm444 ${payload}/SteaMidra.png \
      $out/share/icons/hicolor/256x256/apps/steamidra.png
    cat > $out/share/applications/steamidra.desktop <<EOF
    [Desktop Entry]
    Version=1.0
    Name=SteaMidra
    Comment=Steam game setup and manifest tool
    Exec=steamidra
    TryExec=steamidra
    Icon=steamidra
    Terminal=false
    Type=Application
    Categories=Utility;
    StartupNotify=true
    EOF
  '';

  meta = with lib; {
    description = "Steam game setup and manifest tool (SteaMidra)";
    homepage = "https://github.com/Midrags/SFF";
    license = licenses.gpl3;
    platforms = [ "x86_64-linux" ];
  };
}