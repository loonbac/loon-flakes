{ writeShellApplication
, engramUpdater
}:

writeShellApplication {
  name = "engram";
  runtimeInputs = [ engramUpdater ];

  text = ''
    install_root="''${ENGRAM_INSTALL_ROOT:-$HOME/.local/share/loon-engram}"
    binary="$install_root/current"

    # Engram has no supported self-update command yet. Expose the same UX and
    # delegate it to the checksum-verifying release updater shipped by Nix.
    if [ "''${1:-}" = "update" ]; then
      shift
      exec engram-update "$@"
    fi

    if [ ! -x "$binary" ]; then
      engram-update
    fi

    exec "$binary" "$@"
  '';
}
