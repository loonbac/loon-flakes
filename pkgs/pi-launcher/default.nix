{ writeShellApplication
, nodejs
, useGentleAiDevRuntime ? false
}:

writeShellApplication {
  name = "pi";
  runtimeInputs = [ nodejs ];

  text = ''
    # Keep the writable runtime outside PATH. PI_NPM_PREFIX is a dedicated
    # escape hatch; the user's general npm prefix remains unrelated.
    npm_prefix="''${PI_NPM_PREFIX:-$HOME/.local/share/loon-pi/npm-prefix}"
    mutable_pi="$npm_prefix/bin/pi"

    ${if useGentleAiDevRuntime then ''
      # gentle-pi validates this official field-test override on every use.
      # Keep it in the process environment instead of writing dev-binary.json.
      export GENTLE_PI_GENTLE_AI_DEV_BINARY="''${GENTLE_AI_DEV_INSTALL_ROOT:-$HOME/.local/share/loon-gentle-ai-dev}/gentle-ai"
    '' else ""}

    # Nix owns only this stable launcher. The actual Pi installation stays in
    # the user's writable npm prefix so Pi's supported self-updater can replace
    # it without attempting to mutate /nix/store.
    if [ ! -x "$mutable_pi" ]; then
      mkdir -p "$npm_prefix"
      npm install --global --prefix "$npm_prefix" \
        --ignore-scripts --no-audit --no-fund --loglevel=error \
        @earendil-works/pi-coding-agent@latest >/dev/null
    fi

    # A direct package update remains fully supported. Once Pi has committed
    # the mutable update, replay the declarative layer so downstream patches,
    # generated assets and the observed-version record match the new package.
    # Internal orchestration can suppress this hook and reconcile once at the
    # end of a larger transaction.
    if [ "''${1:-}" = update ] && [ "''${LOON_PI_SKIP_POST_UPDATE_RECONCILE:-0}" != 1 ]; then
      "$mutable_pi" "$@"
      if command -v gentle-ai-bootstrap >/dev/null 2>&1; then
        gentle-ai-bootstrap
        if command -v gentle-ai >/dev/null 2>&1; then
          gentle-ai sync --agent pi
        fi
      else
        echo "pi: update completed; gentle-ai-bootstrap is unavailable, so declarative reconciliation was skipped" >&2
      fi
      exit 0
    fi

    exec "$mutable_pi" "$@"
  '';
}
