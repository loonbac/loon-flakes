# TwintailLauncher — launcher multiplataforma de juegos anime
# (Tauri 2 + WebKitGTK/GTK3, GPL-3.0).
#
# Distribuido como .deb oficial. En NixOS el binario no corre tal cual (falta
# libwebkit2gtk-4.1 y el resto del stack GTK fuera de un árbol FHS), así que:
#   1. extraemos el payload del .deb (binario en usr/bin, resources en
#      usr/lib/twintaillauncher — el layout que Tauri resuelve con
#      resource_dir = exe_dir/../lib/<nombre>),
#   2. envolvemos el binario en un buildFHSEnv con GTK3/WebKitGTK,
#   3. el wrapper final conserva bin/ + lib/ + share/ como en el .deb, y
#      copia .desktop e iconos tal cual los trae la release.
#
# Actualización: cambiar `version` y el `hash` por el de la release nueva de
# https://github.com/TwintailTeam/TwintailLauncher/releases (el .deb amd64).
{ lib, fetchurl, stdenv, dpkg, buildFHSEnv, writeShellScript }:

let
  version = "2.5.2";

  deb = fetchurl {
    url = "https://github.com/TwintailTeam/TwintailLauncher/releases/download/ttl-v${version}/twintaillauncher_${version}_amd64.deb";
    hash = "sha256-KX5QZpYG2adDuN68QB9EQprtXFCjvkdc6l1YlMVAAuI=";
  };

  # Payload del .deb: usr/bin, usr/lib y usr/share.
  payload = stdenv.mkDerivation {
    pname = "twintaillauncher-payload";
    inherit version;
    src = deb;

    nativeBuildInputs = [ dpkg ];
    unpackPhase = ''
      runHook preUnpack
      dpkg-deb -x "$src" .
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      cp -r usr "$out"
      runHook postInstall
    '';
  };

  # FHS con el stack GTK/WebKit que el binario enlaza (y que el resto del
  # sistema no expone fuera de FHS). Los juegos/protones que el launcher
  # descarga corren como hijos dentro del mismo sandbox.
  fhs = buildFHSEnv {
    name = "twintaillauncher-fhs";

    targetPkgs = pkgs: with pkgs; [
      gtk3
      webkitgtk_4_1
      libsoup_3
      cairo
      gdk-pixbuf
      glib
      dbus
      zlib
      xorg.libX11
      libxi
      libayatana-appindicator
    ];

    runScript = "${payload}/bin/twintaillauncher";
  };

  wrapper = writeShellScript "twintaillauncher" ''
    # NVIDIA (GTX 1070): EGL falla al crear la pantalla DRI2 ("failed to create
    # dri2 screen"), pero WebKit 2.54 cae a software sin errores y la ventana
    # renderiza. NO añadir WEBKIT_DISABLE_DMABUF_RENDERER=1 aquí: probado el
    # 2026-11-10 y provocó "WebKit encountered an internal error"
    # (networkProcessCrashed) en cada arranque.
    exec ${fhs}/bin/twintaillauncher-fhs "$@"
  '';
in
stdenv.mkDerivation {
  pname = "twintaillauncher";
  inherit version;

  buildCommand = ''
    install -Dm755 ${wrapper} $out/bin/twintaillauncher
    mkdir -p $out/share
    cp -r ${payload}/share/* $out/share/
  '';

  meta = with lib; {
    description = "Multi-platform launcher for your anime games";
    homepage = "https://github.com/TwintailTeam/TwintailLauncher";
    license = licenses.gpl3;
    platforms = [ "x86_64-linux" ];
    mainProgram = "twintaillauncher";
  };
}
