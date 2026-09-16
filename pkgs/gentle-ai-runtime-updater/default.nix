{ lib
, writeShellApplication
, coreutils
, git
, go
, source ? null
}:

writeShellApplication {
  name = "gentle-ai-runtime-update";
  runtimeInputs = [ coreutils git go ];

  text = ''
    source=${lib.escapeShellArg (if source == null then "" else source)}
    install_root="''${GENTLE_AI_DEV_INSTALL_ROOT:-$HOME/.local/share/loon-gentle-ai-dev}"
    binary="$install_root/gentle-ai"
    source_record="$install_root/source"
    check_only=0
    if_needed=0

    for argument in "$@"; do
      case "$argument" in
        --check) check_only=1 ;;
        --if-needed) if_needed=1 ;;
        --force) if_needed=0 ;;
        *)
          echo "Usage: gentle-ai-runtime-update [--check|--if-needed|--force]" >&2
          exit 2
          ;;
      esac
    done

    if [ -z "$source" ]; then
      echo "Gentle AI runtime: companion verified by gentle-pi."
      exit 0
    fi

    current_source=""
    if [ -f "$source_record" ]; then
      current_source="$(cat "$source_record")"
    fi

    if [ "$check_only" -eq 1 ]; then
      if [ -x "$binary" ] && [ "$current_source" = "$source" ]; then
        echo "Gentle AI development runtime is installed from $source."
      else
        echo "Gentle AI development runtime needs reconciliation: $source"
      fi
      exit 0
    fi

    if [ "$if_needed" -eq 1 ] && [ -x "$binary" ] && [ "$current_source" = "$source" ]; then
      exit 0
    fi

    mkdir -p "$install_root"
    stage="$(mktemp -d "$install_root/.update.XXXXXX")"
    cleanup() {
      rm -rf -- "$stage"
    }
    trap cleanup EXIT

    mkdir -p "$stage/bin"
    (
      export CGO_ENABLED=0
      export GOBIN="$stage/bin"
      go install "$source"
    )

    candidate="$stage/bin/gentle-ai"
    if [ ! -f "$candidate" ] || [ -L "$candidate" ] || [ ! -x "$candidate" ]; then
      echo "gentle-ai-runtime-update: go install did not produce a regular executable" >&2
      exit 1
    fi

    "$candidate" version >/dev/null
    install -m 0755 "$candidate" "$stage/gentle-ai"
    printf '%s\n' "$source" > "$stage/source"
    mv --force "$stage/gentle-ai" "$binary"
    mv --force "$stage/source" "$source_record"

    printf 'Gentle AI development runtime updated from %s: ' "$source"
    "$binary" version
  '';
}
