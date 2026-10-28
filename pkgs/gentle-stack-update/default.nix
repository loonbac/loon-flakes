{ writeShellApplication
, bash
, piLauncher
, gentleAiBootstrap
, gentleAiLauncher
, gentleAiRuntimeUpdater
, engramLauncher
, nodejs
, gentlePiPackageSubpath ? "npm/node_modules/gentle-pi"
}:

writeShellApplication {
  name = "gentle-stack-update";
  runtimeInputs = [
    bash
    piLauncher
    gentleAiBootstrap
    gentleAiLauncher
    gentleAiRuntimeUpdater
    engramLauncher
    nodejs
  ];

  text = ''
    npm_prefix="''${PI_NPM_PREFIX:-$HOME/.local/share/loon-pi/npm-prefix}"

    # Pi updates itself from the writable global npm prefix. Reconcile first
    # so installations migrated from the old Nix closure use unversioned
    # extension sources before Pi evaluates their available updates.
    LOON_PI_SKIP_POST_UPDATE_RECONCILE=1 pi update
    gentle-ai-runtime-update
    engram update
    gentle-ai-bootstrap
    # CodeGraph owns its mutable npm installation. `codegraph upgrade` runs
    # npm without --prefix, so it lands in npm's global prefix (~/.npm-global)
    # and leaves the copy Nix launches stale; install it into the managed
    # prefix the same way gentle-ai-bootstrap does. This step is reached only
    # through the user's explicit full-stack update request.
    npm install --global --prefix "$npm_prefix" \
      --include=optional --ignore-scripts --no-audit --no-fund --loglevel=error \
      @colbymchenry/codegraph
    LOON_PI_SKIP_POST_UPDATE_RECONCILE=1 pi update --extensions
    # An extension update can ship new agent assets. Apply the declarative
    # model routes again and verify gentle-pi's companion runtime afterwards.
    gentle-ai-bootstrap
    gentle-ai sync --agent pi

    printf '\nActive versions:\n'
    printf '  Pi:        '
    pi --version
    printf '  Gentle AI: '
    gentle-ai version
    printf '  Gentle Pi: '
    node -p 'require(process.env.HOME + "/.pi/agent/${gentlePiPackageSubpath}/package.json").version'
    printf '  Engram:    '
    engram version
    printf '  CodeGraph: '
    "$npm_prefix/bin/codegraph" --version
  '';
}
