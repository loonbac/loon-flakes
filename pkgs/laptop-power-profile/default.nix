{ pkgs
, mpvpaperWallpaper ? pkgs.callPackage ../mpvpaper-wallpaper {
    accent-wallpaper = pkgs.callPackage ../accent-wallpaper { };
  }
}:

let
  rootProfile = pkgs.writeShellApplication {
    name = "laptop-power-profile";
    runtimeInputs = with pkgs; [
      bluez coreutils gawk gnugrep hdparm iw networkmanager procps systemd util-linux
    ];
    text = builtins.readFile ./laptop-power-profile.sh;
  };

  sessionProfile = pkgs.writeShellApplication {
    name = "laptop-power-profile-session";
    runtimeInputs = with pkgs; [ coreutils jq niri mpvpaperWallpaper ];
    text = builtins.readFile ./laptop-power-profile-session.sh;
  };
in
pkgs.symlinkJoin {
  name = "laptop-power-profile";
  paths = [ rootProfile sessionProfile ];
}
