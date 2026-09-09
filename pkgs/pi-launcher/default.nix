{ writeShellApplication
, nodejs
}:

writeShellApplication {
  name = "pi";
  runtimeInputs = [ nodejs ];

  text = ''
    # Keep the writable runtime outside PATH. PI_NPM_PREFIX is a dedicated
    # escape hatch; the user's general npm prefix remains unrelated.
    npm_prefix="''${PI_NPM_PREFIX:-$HOME/.local/share/loon-pi/npm-prefix}"
    mutable_pi="$npm_prefix/bin/pi"

    # Nix owns only this stable launcher. The actual Pi installation stays in
    # the user's writable npm prefix so Pi's supported self-updater can replace
    # it without attempting to mutate /nix/store.
    if [ ! -x "$mutable_pi" ]; then
      mkdir -p "$npm_prefix"
      npm install --global --prefix "$npm_prefix" \
        --ignore-scripts --no-audit --no-fund --loglevel=error \
        @earendil-works/pi-coding-agent@latest >/dev/null
    fi

    exec "$mutable_pi" "$@"
  '';
}
