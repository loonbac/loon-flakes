{ lib
, writeShellApplication
, coreutils
, bash
, nodejs
, pnpm
, go
, git
}:

writeShellApplication {
  name = "gentle-shell";
  runtimeInputs = [ coreutils bash nodejs pnpm go git ];

  text = ''
    # Wrapper Nix sobre el binario upstream de Gentle Shell (Path A:
    # `npm i -g gentle-pi`). El binario real vive en un prefijo mutable del
    # home y ya implementa upgrade/--channel/--rollback; este wrapper solo:
    #   - resuelve ese prefijo (LOON_GENTLE_SHELL_ROOT para pruebas),
    #   - guarda la versión anterior antes de cada upgrade (rollback
    #     garantizado aunque el modo npm-global no conserve versiones),
    #   - aporta pnpm+Go+git para el canal main,
    #   - avisa qué poner en el .nix cuando cambias de canal (si no, el
    #     bootstrap lo revierte al entrar, por diseño declarativo).
    managed="''${LOON_GENTLE_SHELL_ROOT:-$HOME/.local/share/loon-gentle-shell}"
    real_bin="$managed/bin/gentle-shell"
    previous_file="$managed/.previous-shell-version"

    die() { echo "gentle-shell: $*" >&2; exit 1; }

    [ -x "$real_bin" ] || die "no instalado en $managed. Corre gentle-ai-bootstrap (respeta channel/version del .nix)."

    current_version() { "$real_bin" --version 2>/dev/null | head -1; }

    if [ "''${1:-}" = "upgrade" ]; then
      # The upstream binary resolves npm ownership through `npm root -g`, which only
      # sees this prefix when npm's own prefix points at it (the ambient
      # NPM_CONFIG_PREFIX may point elsewhere, e.g. ~/.npm-global).
      export NPM_CONFIG_PREFIX="$managed"
      case "''${2:-}" in
        --rollback)
          [ -f "$previous_file" ] || die "no hay versión anterior guardada (se guarda sola antes de cada upgrade)."
          prev="$(cat "$previous_file")"
          [ -n "$prev" ] || die "archivo de versión anterior vacío."
          echo "gentle-shell: volviendo a la versión anterior guardada: $prev"
          npm install --global --prefix "$managed" \
            --no-audit --no-fund --loglevel=error "gentle-pi@$prev" \
            || die "falló la reinstalación de gentle-pi@$prev; la instalación actual no se tocó."
          echo "gentle-shell: rollback completo:"
          current_version
          exit 0
          ;;
        --channel|--channel=*)
          # El binario real hace el cambio ahora mismo (release: instala;
          # main: compila desde fuente con el pnpm+Go que aporta este wrapper).
          before="$(current_version)"
          [ -n "$before" ] && printf '%s\n' "$before" > "$previous_file"
          echo "gentle-shell: cambiando de canal ahora. Para hacerlo permanente,"
          echo "  en tu .nix: programs.gentle-ai.gentleShell.channel = \"<release|main>\"; + rebuild"
          echo "  (sin eso, el bootstrap restaura el canal declarado al entrar)."
          ;;
        "")
          before="$(current_version)"
          [ -n "$before" ] && printf '%s\n' "$before" > "$previous_file"
          ;;
      esac
    fi

    export PATH="$managed/bin:$PATH"
    exec "$real_bin" "$@"
  '';
}
