{ pkgs
, mpvpaperWallpaper ? pkgs.callPackage ../mpvpaper-wallpaper {
    accent-wallpaper = pkgs.callPackage ../accent-wallpaper { };
  }
}:

pkgs.writeShellApplication {
  name = "niri-wallpaper-visibility";
  runtimeInputs = [ pkgs.niri pkgs.python3 mpvpaperWallpaper ];
  text = ''
    exec python3 ${./watcher.py}
  '';
}
