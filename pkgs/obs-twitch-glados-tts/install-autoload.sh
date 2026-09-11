#!/usr/bin/env bash
set -euo pipefail

readonly script_path="/etc/obs-scripts/twitch-glados-tts.py"
readonly obs_config="${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio"
readonly scenes_dir="$obs_config/basic/scenes"
readonly user_config="$obs_config/user.ini"

# On Linux OBS has Python scripting support compiled in, but it does not load
# libpython until this path is present in user.ini.
if [[ -f "$user_config" ]]; then
  if grep -q '^Path64bit=' "$user_config"; then
    sed -i "s|^Path64bit=.*|Path64bit=$OBS_TWITCH_TTS_PYTHON_PATH|" "$user_config"
  elif grep -q '^\[Python\]$' "$user_config"; then
    sed -i "/^\[Python\]$/a Path64bit=$OBS_TWITCH_TTS_PYTHON_PATH" "$user_config"
  else
    printf '\n[Python]\nPath64bit=%s\n' "$OBS_TWITCH_TTS_PYTHON_PATH" >> "$user_config"
  fi
fi

[[ -d "$scenes_dir" ]] || exit 0

shopt -s nullglob
for scene in "$scenes_dir"/*.json; do
  if jq -e --arg path "$script_path" '
    any(.modules."scripts-tool"[]?; .path == $path)
  ' "$scene" >/dev/null; then
    continue
  fi

  temporary="${scene}.glados-tts.tmp"
  jq --arg path "$script_path" '
    (.modules."scripts-tool" // []) as $scripts
    | ([
        $scripts[]?
        | select(((.path // "") | endswith("/twitch-glados-tts.py")) | not)
      ]) as $other_scripts
    | ([
        $scripts[]?
        | select((.path // "") | endswith("/twitch-glados-tts.py"))
        | .settings
      ][0] // {
        channel: "loonbac21",
        command: "!t",
        max_chars: 220,
        user_cooldown: 12,
        queue_limit: 6,
        volume: 80,
        monitor: true,
        speed: 1.0,
        test_text: "Hola. Esta es una prueba del sistema de Aperture Science."
      }) as $saved_settings
    | .modules."scripts-tool" = ($other_scripts + [{
        path: $path,
        settings: $saved_settings
      }])
    | del(."scripts-tool")
  ' "$scene" > "$temporary"
  chmod --reference="$scene" "$temporary"
  mv "$temporary" "$scene"
done
