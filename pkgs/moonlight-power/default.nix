# Session-scoped power mode for Moonlight.  The user command and the root
# helper are separate executables so the NixOS module can give each a fixed,
# narrow lifecycle.
{ pkgs
, accentWallpaper ? pkgs.callPackage ../accent-wallpaper { }
, mpvpaperWallpaper ? pkgs.callPackage ../mpvpaper-wallpaper {
    accent-wallpaper = accentWallpaper;
  }
, niriBackdrop ? pkgs.callPackage ../niri-backdrop {
    accent-wallpaper = accentWallpaper;
  }
, screenBrightness ? pkgs.callPackage ../screen-brightness { }
, loonLaunch ? pkgs.callPackage ../loon-launch { }
}:

let
  runtimeInputs = with pkgs; [
    bash coreutils findutils gawk gnugrep iw jq networkmanager procps
    systemd util-linux niri waybar swaynotificationcenter udiskie
    wl-clipboard wl-clip-persist cliphist moonlight-qt
    mpvpaperWallpaper niriBackdrop screenBrightness loonLaunch
  ];

  rootHelper = pkgs.writeShellApplication {
    name = "moonlight-power-root";
    inherit runtimeInputs;
    text = builtins.readFile ./moonlight-power-root.sh;
  };

  userTool = pkgs.writeShellApplication {
    name = "moonlight-power";
    inherit runtimeInputs;
    text = builtins.readFile ./moonlight-power.sh;
  };

  focusedTests = pkgs.runCommand "moonlight-power-focused-tests" {
    nativeBuildInputs = with pkgs; [ bash coreutils gnugrep jq ];
  } ''
    ${pkgs.bash}/bin/bash ${./tests/test-root.sh} \
      ${rootHelper}/bin/moonlight-power-root \
      ${userTool}/bin/moonlight-power
    touch "$out"
  '';
in
pkgs.symlinkJoin {
  name = "moonlight-power";
  paths = [ rootHelper userTool ];
  passthru.tests.focused = focusedTests;
}
