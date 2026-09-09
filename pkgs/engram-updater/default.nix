{ writeShellApplication
, coreutils
, curl
, gawk
, gnugrep
, gnutar
, gzip
, jq
, util-linux
}:

writeShellApplication {
  name = "engram-update";
  runtimeInputs = [ coreutils curl gawk gnugrep gnutar gzip jq util-linux ];

  text = ''
    install_root="''${ENGRAM_INSTALL_ROOT:-$HOME/.local/share/loon-engram}"
    releases_root="$install_root/releases"
    current_link="$install_root/current"
    check_only=0
    force=0

    for argument in "$@"; do
      case "$argument" in
        --check) check_only=1 ;;
        --force) force=1 ;;
        *)
          echo "Usage: engram update [--check] [--force]" >&2
          exit 2
          ;;
      esac
    done

    mkdir -p "$releases_root"
    exec 9>"$install_root/update.lock"
    flock 9

    stage="$(mktemp -d "$install_root/.update.XXXXXX")"
    cleanup() {
      rm -rf -- "$stage"
    }
    trap cleanup EXIT

    api_url="https://api.github.com/repos/Gentleman-Programming/engram/releases/latest"
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

    current_version=""
    if [ -L "$current_link" ]; then
      current_target="$(readlink -f "$current_link" || true)"
      case "$current_target" in
        "$releases_root"/*/engram)
          current_version="$(basename "$(dirname "$current_target")")"
          ;;
      esac
    fi

    if [ "$check_only" -eq 1 ]; then
      if [ "$current_version" = "$version" ]; then
        echo "Engram is already up to date (v$version)."
      else
        echo "Engram update available: ''${current_version:-not installed} -> $version"
      fi
      exit 0
    fi

    release_dir="$releases_root/$version"
    if [ "$force" -eq 0 ] && [ "$current_version" = "$version" ] && [ -x "$current_link" ]; then
      echo "Engram is already up to date (v$version)."
      exit 0
    fi

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

    if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
      mv "$release_dir" "$releases_root/$version.replaced.$(date +%Y%m%d%H%M%S)"
    fi
    mv "$stage/release" "$release_dir"
    ln -s "releases/$version/engram" "$stage/current"
    mv --force --no-target-directory "$stage/current" "$current_link"

    echo "Engram updated to v$version."
  '';
}
