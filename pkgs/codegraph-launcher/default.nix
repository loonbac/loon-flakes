{ writeShellApplication
, nodejs
}:

writeShellApplication {
  name = "codegraph";
  runtimeInputs = [ nodejs ];

  text = ''
    npm_prefix="''${PI_NPM_PREFIX:-$HOME/.local/share/loon-pi/npm-prefix}"
    mutable_codegraph="$npm_prefix/bin/codegraph"

    if [ ! -x "$mutable_codegraph" ]; then
      echo "codegraph: CLI no instalado; ejecuta gentle-ai-bootstrap" >&2
      exit 127
    fi

    exec "$mutable_codegraph" "$@"
  '';
}
