{ writeShellApplication
, nodejs
}:

writeShellApplication {
  name = "cline";
  runtimeInputs = [ nodejs ];

  text = ''
    npm_prefix="''${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"
    cline_bin="$npm_prefix/bin/cline"

    # Exporta SSL_CERT_DIR si /etc/ssl/certs existe, evitando advertencias de certificados
    # OpenSSL en runtimes Node embebidos y binarios nativos bajo NixOS.
    if [ -d "/etc/ssl/certs" ] && [ -z "''${SSL_CERT_DIR:-}" ]; then
      export SSL_CERT_DIR="/etc/ssl/certs"
    fi

    # Nix es dueño únicamente de este launcher estable. La instalación mutable
    # de Cline vive en el prefijo npm del usuario para permitir actualizaciones
    # mediante `npm i -g cline` o `cline update` sin mutar /nix/store ni causar
    # downgrades tras un rebuild de NixOS.
    if [ ! -x "$cline_bin" ]; then
      echo "cline: no encontrado en $cline_bin; instalando via npm en $npm_prefix..." >&2
      mkdir -p "$npm_prefix"
      if ! npm install --global --prefix "$npm_prefix" \
        --no-audit --no-fund --loglevel=error cline; then
        echo "cline: error al instalar cline desde npm" >&2
        exit 1
      fi
    fi

    exec "$cline_bin" "$@"
  '';
}
