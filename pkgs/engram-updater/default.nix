{ lib
, writeShellApplication
, coreutils
, curl
, gawk
, git
, gnugrep
, gnutar
, go
, gzip
, jq
, util-linux
, sourceMode ? "release"
, sourceRef ? null
}:

writeShellApplication {
  name = "engram-update";
  runtimeInputs = [ coreutils curl gawk git gnugrep gnutar go gzip jq util-linux ];

  text = ''
    source_mode=${lib.escapeShellArg sourceMode}
    source_ref=${lib.escapeShellArg (if sourceRef == null then "" else sourceRef)}
    install_root="''${ENGRAM_INSTALL_ROOT:-$HOME/.local/share/loon-engram}"
    releases_root="$install_root/releases"
    current_link="$install_root/current"
    request_record="$install_root/source-request"
    resolved_record="$install_root/source-resolved"
    check_only=0
    if_needed=0
    force=0

    for argument in "$@"; do
      case "$argument" in
        --check) check_only=1 ;;
        --if-needed) if_needed=1 ;;
        --force) force=1 ;;
        *)
          echo "Usage: engram update [--check|--if-needed|--force]" >&2
          exit 2
          ;;
      esac
    done

    case "$source_mode" in
      release|git) ;;
      *)
        echo "engram-update: unsupported source mode: $source_mode" >&2
        exit 2
        ;;
    esac

    if [ "$source_mode" = release ] && [ -n "$source_ref" ] \
      && [[ ! "$source_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
      echo "engram-update: release refs must be tags such as v2.0.0-rc.11" >&2
      exit 2
    fi
    if [ "$source_mode" = git ] && [ -z "$source_ref" ]; then
      source_ref=main
    fi

    request="$source_mode:''${source_ref:-latest}"
    current_request=""
    current_resolved=""
    [ ! -f "$request_record" ] || current_request="$(cat "$request_record")"
    [ ! -f "$resolved_record" ] || current_resolved="$(cat "$resolved_record")"

    # A fixed release or Git ref only needs network access when the declaration
    # changes. Moving refs are refreshed explicitly through `engram update`.
    if [ "$if_needed" -eq 1 ] && [ "$current_request" = "$request" ] \
      && [ -x "$current_link" ]; then
      exit 0
    fi

    mkdir -p "$releases_root"
    exec 9>"$install_root/update.lock"
    flock 9

    stage="$(mktemp -d "$install_root/.update.XXXXXX")"
    cleanup() {
      rm -rf -- "$stage"
    }
    trap cleanup EXIT

    repo_url="https://github.com/Gentleman-Programming/engram.git"
    if [ "$source_mode" = release ]; then
      if [ -n "$source_ref" ]; then
        api_url="https://api.github.com/repos/Gentleman-Programming/engram/releases/tags/$source_ref"
      else
        api_url="https://api.github.com/repos/Gentleman-Programming/engram/releases/latest"
      fi
      curl --fail --silent --show-error --location \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url" --output "$stage/release.json"

      tag="$(jq -er '.tag_name' "$stage/release.json")"
      if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        echo "engram-update: GitHub returned an invalid release tag: $tag" >&2
        exit 1
      fi
      version="''${tag#v}"
      resolved="release:$tag"
    else
      mkdir -p "$stage/repo"
      git -C "$stage/repo" init --quiet
      git -C "$stage/repo" remote add origin "$repo_url"
      git -C "$stage/repo" fetch --quiet --depth 1 origin "$source_ref"
      git -C "$stage/repo" checkout --quiet --detach FETCH_HEAD
      revision="$(git -C "$stage/repo" rev-parse HEAD)"
      short_revision="$(printf '%s' "$revision" | cut -c1-12)"
      version="git-$short_revision"
      resolved="git:$source_ref@$revision"
    fi

    if [ "$check_only" -eq 1 ]; then
      if [ "$current_request" = "$request" ] && [ "$current_resolved" = "$resolved" ] \
        && [ -x "$current_link" ]; then
        echo "Engram is already reconciled ($resolved)."
      else
        echo "Engram update available: ''${current_resolved:-not installed} -> $resolved"
      fi
      exit 0
    fi

    if [ "$force" -eq 0 ] && [ "$current_request" = "$request" ] \
      && [ "$current_resolved" = "$resolved" ] && [ -x "$current_link" ]; then
      echo "Engram is already up to date ($resolved)."
      exit 0
    fi

    if [ "$source_mode" = release ]; then
      case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) platform="linux_amd64" ;;
        Linux-aarch64) platform="linux_arm64" ;;
        *)
          echo "engram-update: unsupported platform $(uname -s)/$(uname -m)" >&2
          exit 1
          ;;
      esac

      asset="engram_''${version}_''${platform}.tar.gz"
      asset_url="$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' "$stage/release.json")"
      checksums_url="$(jq -er '.assets[] | select(.name == "checksums.txt") | .browser_download_url' "$stage/release.json")"
      curl --fail --silent --show-error --location "$asset_url" --output "$stage/$asset"
      curl --fail --silent --show-error --location "$checksums_url" --output "$stage/checksums.txt"
      expected="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$stage/checksums.txt")"
      if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "engram-update: no valid SHA-256 was published for $asset" >&2
        exit 1
      fi
      printf '%s  %s\n' "$expected" "$stage/$asset" | sha256sum --check --status

      mkdir -p "$stage/extract" "$stage/release"
      tar --extract --gzip --file "$stage/$asset" --directory "$stage/extract"
      if [ ! -f "$stage/extract/engram" ] || [ -L "$stage/extract/engram" ]; then
        echo "engram-update: the verified archive does not contain a regular engram binary" >&2
        exit 1
      fi
      install -m 0755 "$stage/extract/engram" "$stage/release/engram"
      reported_version="$("$stage/release/engram" version)"
      if [ "$reported_version" != "engram $version" ]; then
        echo "engram-update: binary reported '$reported_version', expected 'engram $version'" >&2
        exit 1
      fi

    else
      mkdir -p "$stage/release"
      (
        cd "$stage/repo"
        export CGO_ENABLED=0
        go build -trimpath -ldflags "-s -w -X main.version=$version" \
          -o "$stage/release/engram" ./cmd/engram
      )
      if [ "$("$stage/release/engram" version)" != "engram $version" ]; then
        echo "engram-update: source build did not report the selected revision" >&2
        exit 1
      fi
    fi

    release_dir="$releases_root/$version"
    if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
      mv "$release_dir" "$releases_root/$version.replaced.$(date +%Y%m%d%H%M%S)"
    fi
    mv "$stage/release" "$release_dir"

    ln -s "releases/$version/engram" "$stage/current"
    mv --force --no-target-directory "$stage/current" "$current_link"
    printf '%s\n' "$request" > "$stage/source-request"
    printf '%s\n' "$resolved" > "$stage/source-resolved"
    mv --force "$stage/source-request" "$request_record"
    mv --force "$stage/source-resolved" "$resolved_record"

    echo "Engram updated to $resolved."
  '';
}
