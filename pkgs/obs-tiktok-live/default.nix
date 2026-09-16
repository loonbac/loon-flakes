{
  lib,
  buildNpmPackage,
  bash,
  coreutils,
  gnugrep,
  gnused,
  jq,
  makeWrapper,
  nodejs_22,
  writeShellApplication,
}:

let
  autoload = writeShellApplication {
    name = "obs-tiktok-live-autoload";
    runtimeInputs = [ jq coreutils gnugrep gnused ];
    text = ''
      set -euo pipefail
      readonly script_path="/etc/obs-scripts/tiktok-live.py"
      readonly scenes_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/basic/scenes"
      [[ -d "$scenes_dir" ]] || exit 0

      shopt -s nullglob
      for scene in "$scenes_dir"/*.json; do
        if jq -e --arg path "$script_path" 'any(.modules."scripts-tool"[]?; .path == $path)' "$scene" >/dev/null; then
          continue
        fi
        temporary="''${scene}.tiktok-live.tmp"
        jq --arg path "$script_path" '
          (.modules."scripts-tool" // []) as $scripts
          | ([ $scripts[]? | select(((.path // "") | endswith("/tiktok-live.py")) | not) ]) as $other
          | ([ $scripts[]? | select((.path // "") | endswith("/tiktok-live.py")) | .settings ][0] // {
              unique_id: "", show_joins: true, show_likes: true
            }) as $settings
          | .modules."scripts-tool" = ($other + [{ path: $path, settings: $settings }])
          | del(."scripts-tool")
        ' "$scene" > "$temporary"
        chmod --reference="$scene" "$temporary"
        mv "$temporary" "$scene"
      done
    '';
  };
in
buildNpmPackage {
  pname = "obs-tiktok-live";
  version = "1.0.0";
  src = ./.;

  npmDepsHash = "sha256-LoZs+SQzYdurXRyhA+v63VVSJkPT9eOL9w+g6+3W0Yo=";
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/lib/obs-tiktok-live"
    substitute service.mjs "$out/lib/obs-tiktok-live/service.mjs"
    mkdir -p "$out/share/obs-scripts"
    substitute tiktok-live.py "$out/share/obs-scripts/tiktok-live.py" \
      --replace-fail '@serviceBinary@' "$out/bin/obs-tiktok-live"
    cp -R node_modules "$out/lib/obs-tiktok-live/node_modules"

    makeWrapper ${lib.getExe nodejs_22} "$out/bin/obs-tiktok-live" \
      --add-flags "$out/lib/obs-tiktok-live/service.mjs"
    ln -s ${autoload}/bin/obs-tiktok-live-autoload "$out/bin/obs-tiktok-live-autoload"

    runHook postInstall
  '';

  meta = {
    description = "Local TikTok LIVE chat and alert service for OBS";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
  };
}
