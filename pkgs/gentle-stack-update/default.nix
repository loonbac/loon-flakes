{ writeShellApplication
, bash
, piLauncher
, gentleAiBootstrap
, gentleAiLauncher
, engramLauncher
, nodejs
}:

writeShellApplication {
  name = "gentle-stack-update";
  runtimeInputs = [ bash piLauncher gentleAiBootstrap gentleAiLauncher engramLauncher nodejs ];

  text = ''
    # Pi updates itself from the writable global npm prefix. Reconcile first
    # so installations migrated from the old Nix closure use unversioned
    # extension sources before Pi evaluates their available updates.
    pi update
    engram update
    gentle-ai-bootstrap
    pi update --extensions
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
    node -p 'require(process.env.HOME + "/.pi/agent/npm/node_modules/gentle-pi/package.json").version'
    printf '  Engram:    '
    engram version
  '';
}
