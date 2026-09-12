{ lib, appimageTools, fetchurl, makeDesktopItem }:

let
  version = "1.4.200";
  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/orca-linux.AppImage";
    hash = "sha256-yC2d31MkMeDaUexdGJmg4xWqu453/ORezOf61HM/yWo=";
  };

  desktopItem = makeDesktopItem {
    name = "orca";
    desktopName = "Orca";
    comment = "Agent development environment";
    exec = "orca-ide %U";
    icon = "orca";
    categories = [ "Development" "IDE" ];
    startupNotify = true;
  };
in
appimageTools.wrapType2 {
  pname = "orca-ide";
  inherit version src;

  extraInstallCommands = ''
    install -Dm444 ${desktopItem}/share/applications/orca.desktop \
      "$out/share/applications/orca.desktop"
  '';

  meta = {
    description = "Orca agent development environment";
    homepage = "https://www.onorca.dev/";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "orca-ide";
  };
}
