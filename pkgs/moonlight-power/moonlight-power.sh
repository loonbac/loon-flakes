# Session half of moonlight-power.  All command lines below are fixed; state
# data never becomes a command or a path.  The root half is reached only by
# start/stop of its fixed systemd unit.
set +e

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/moonlight-power"
test_bin=
if [ "${MOONLIGHT_POWER_TESTING:-0}" = 1 ]; then
  test_bin=${MOONLIGHT_POWER_TEST_BIN_DIR:?missing test bin}
  state_dir=${MOONLIGHT_POWER_USER_STATE_DIR:?missing test user state directory}
fi
state_file=$state_dir/state.json
lock_file=$state_dir/lock
user_unit='moonlight-power-user.service'
root_unit='moonlight-power-root.service'

bin() {
  if [ -n "$test_bin" ]; then printf '%s/%s\n' "$test_bin" "$1"; else printf '%s\n' "$1"; fi
}
systemctl=$(bin systemctl)
if [ -n "$test_bin" ]; then sudo_cmd="$test_bin/sudo"; else sudo_cmd=/run/wrappers/bin/sudo; fi
niri=$(bin niri)
screen_brightness=$(bin screen-brightness)
mpvpaper_wallpaper=$(bin mpvpaper-wallpaper)
niri_backdrop=$(bin niri-backdrop)
waybar=$(bin waybar)
swaync=$(bin swaync)
udiskie=$(bin udiskie)
wl_clip_persist=$(bin wl-clip-persist)
wl_paste=$(bin wl-paste)
cliphist=$(bin cliphist)
loon_launch=$(bin loon-launch)
moonlight=$(bin moonlight)
pgrep_cmd=$(bin pgrep)
pkill_cmd=$(bin pkill)
setsid_cmd=$(bin setsid)

err() { echo "moonlight-power: $*" >&2; return 1; }
token() { case "${1:-}" in ""|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
mode() { printf '%s\n' "${1:-}" | grep -Eq '^[0-9]{2,5}x[0-9]{2,5}@[0-9]{1,3}\.[0-9]{1,3}$'; }
boot_id() {
  local id
  id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
  printf '%s\n' "$id" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
  printf '%s\n' "$id"
}
init() {
  mkdir -p "$state_dir" || return 1
  chmod 0700 "$state_dir" || return 1
  touch "$lock_file" || return 1
  chmod 0600 "$lock_file" || return 1
  exec 9>"$lock_file" || return 1
  flock -x 9
}
save() {
  local payload=$1 tmp
  tmp=$(mktemp "$state_dir/.state.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$payload" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$state_file"
}
valid_state() {
  [ -f "$state_file" ] || return 1
  jq -e '
    type == "object" and .version == 1
    and (.boot_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.phase == "snapshot" or .phase == "active" or .phase == "restoring" or .phase == "degraded")
    and (.output | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and (.mode | type == "string" and test("^[0-9]{2,5}x[0-9]{2,5}@[0-9]{1,3}\\.[0-9]{1,3}$"))
    and (.brightness | type == "number" and . >= 0 and . <= 100 and floor == .)
    and (.processes | type == "object"
      and (.animated_wallpaper,.static_wallpaper,.waybar,.swaync,.udiskie,.clip_persist,
           .wl_paste_text,.wl_paste_image,.loon_launch | type == "boolean"))
    and (.timer_active | type == "boolean")
  ' "$state_file" >/dev/null 2>&1
}
phase() {
  local payload
  payload=$(jq -ce --arg phase "$1" '.phase = $phase' "$state_file") || return 1
  save "$payload"
}
bool() {
  local command=$1
  shift
  if "$command" "$@"; then printf true; else printf false; fi
}
running() { "$pgrep_cmd" -f "$1" >/dev/null 2>&1; }
stop_match() {
  # pgrep/pkill use 1 for a harmless "no matching process" and >=2 for a
  # real error.  Preserve the latter so partial failure is recoverable.
  local rc
  "$pkill_cmd" -f "$1" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
}
start_if_absent() {
  local pattern=$1
  shift
  running "$pattern" && return 0
  # Do not leak the state lock into restored long-lived desktop processes.
  "$setsid_cmd" "$@" 9>&- >/dev/null 2>&1 < /dev/null &
}
display() {
  # Niri reports refresh rates in mHz.  Select an advertised 59-61 Hz mode at
  # the current resolution and retain the exact current mode for rollback.
  "$niri" msg -j outputs 2>/dev/null | jq -ce '
    [ to_entries[] | select(.value.current_mode? != null) | .key as $name | .value as $output
      | $output.modes[$output.current_mode] as $current
      | first($output.modes[]? | select(.width == $current.width and .height == $current.height)
          | select((.refresh_rate | tonumber) >= 59000 and (.refresh_rate | tonumber) <= 61000)) as $low
      | select($low != null)
      | { output: $name,
          mode: "\($current.width)x\($current.height)@\(($current.refresh_rate | tonumber) / 1000)",
          low: "\($low.width)x\($low.height)@\(($low.refresh_rate | tonumber) / 1000)" }
    ] | first | select(. != null)
  '
}
set_brightness_checked() {
  local target=$1 actual
  "$screen_brightness" set "$target" >/dev/null 2>&1 || return 1
  actual=$("$screen_brightness" get 2>/dev/null) || return 1
  [ "$actual" = "$target" ] || { err "brightness readback mismatch: wanted $target, got $actual"; return 1; }
}
set_mode_checked() {
  local output=$1 target=$2 actual
  "$niri" msg output "$output" mode "$target" >/dev/null 2>&1 || return 1
  actual=$(display | jq -r .mode) || return 1
  [ "$actual" = "$target" ] || { err "display mode readback mismatch: wanted $target, got $actual"; return 1; }
}
snapshot() {
  local screen boot output original brightness timer
  local animated static bar notifications disks persist text image launcher
  screen=$(display) || { err "no current-resolution ~60 Hz niri mode found"; return 1; }
  output=$(printf '%s' "$screen" | jq -r .output)
  original=$(printf '%s' "$screen" | jq -r .mode)
  if ! token "$output" || ! mode "$original"; then err "invalid niri output data"; return 1; fi
  brightness=$("$screen_brightness" get 2>/dev/null) || { err "cannot read logical brightness"; return 1; }
  case "$brightness" in ''|*[!0-9]*) err "invalid logical brightness"; return 1;; esac
  [ "$brightness" -le 100 ] || { err "brightness is outside 0-100"; return 1; }
  boot=$(boot_id) || { err "cannot read boot ID"; return 1; }
  animated=$(bool running '[b]in/mpvpaper ')
  static=$(bool running 'awww-daemon.*--namespace wallpaper')
  bar=$(bool running '(^|/)waybar$')
  notifications=$(bool running '(^|/)swaync$')
  disks=$(bool running '(^|/)(\.udiskie-wrapped|udiskie) --automount --notify$')
  persist=$(bool running 'wl-clip-persist --clipboard both$')
  text=$(bool running 'wl-paste --type text --watch cliphist store$')
  image=$(bool running 'wl-paste --type image --watch cliphist store$')
  launcher=$(bool running '(^|/)loon-launch$')
  if "$systemctl" --user is-active --quiet nixos-updates-check.timer >/dev/null 2>&1; then timer=true; else timer=false; fi
  jq -cn --arg boot_id "$boot" --arg output "$output" --arg mode "$original" --argjson brightness "$brightness" \
    --argjson animated "$animated" --argjson static "$static" --argjson bar "$bar" --argjson notifications "$notifications" \
    --argjson disks "$disks" --argjson persist "$persist" --argjson text "$text" --argjson image "$image" \
    --argjson launcher "$launcher" --argjson timer "$timer" \
    '{version:1,boot_id:$boot_id,phase:"snapshot",output:$output,mode:$mode,brightness:$brightness,
      processes:{animated_wallpaper:$animated,static_wallpaper:$static,waybar:$bar,swaync:$notifications,
        udiskie:$disks,clip_persist:$persist,wl_paste_text:$text,wl_paste_image:$image,loon_launch:$launcher},
      timer_active:$timer}'
}
state_bool() { jq -r "$1" "$state_file" 2>/dev/null; }
apply_values() {
  local failed=0 output low brightness target
  output=$(jq -r .output "$state_file") || failed=1
  low=$(display | jq -r .low) || failed=1
  brightness=$(jq -r .brightness "$state_file") || failed=1
  token "$output" && mode "$low" && set_mode_checked "$output" "$low" || failed=1
  if [ "$brightness" -gt 20 ] 2>/dev/null; then target=20; else target=$brightness; fi
  set_brightness_checked "$target" || failed=1
  "$mpvpaper_wallpaper" stop >/dev/null 2>&1 || failed=1
  "$niri_backdrop" stop >/dev/null 2>&1 || failed=1
  stop_match '(^|/)waybar$' || failed=1
  stop_match '(^|/)swaync$' || failed=1
  stop_match '(^|/)(\.udiskie-wrapped|udiskie) --automount --notify$' || failed=1
  stop_match 'wl-clip-persist --clipboard both$' || failed=1
  stop_match 'wl-paste --type text --watch cliphist store$' || failed=1
  stop_match 'wl-paste --type image --watch cliphist store$' || failed=1
  stop_match '(^|/)loon-launch$' || failed=1
  [ "$(state_bool .timer_active)" = true ] && "$systemctl" --user stop nixos-updates-check.timer >/dev/null 2>&1 || true
  [ "$failed" -eq 0 ]
}
restore_values() {
  # Each action is attempted even if an earlier one fails.  A failure leaves
  # the state at phase=degraded so `recover` can safely repeat the rollback.
  local failed=0 output original brightness
  output=$(jq -r .output "$state_file") || failed=1
  original=$(jq -r .mode "$state_file") || failed=1
  brightness=$(jq -r .brightness "$state_file") || failed=1
  token "$output" && mode "$original" && set_mode_checked "$output" "$original" || failed=1
  set_brightness_checked "$brightness" || failed=1
  if [ "$(state_bool .processes.animated_wallpaper)" = true ]; then start_if_absent '[b]in/mpvpaper ' "$mpvpaper_wallpaper" || failed=1; fi
  if [ "$(state_bool .processes.static_wallpaper)" = true ]; then start_if_absent 'awww-daemon.*--namespace wallpaper' "$niri_backdrop" || failed=1; fi
  if [ "$(state_bool .processes.waybar)" = true ]; then start_if_absent '(^|/)waybar$' "$waybar" || failed=1; fi
  if [ "$(state_bool .processes.swaync)" = true ]; then start_if_absent '(^|/)swaync$' "$swaync" || failed=1; fi
  if [ "$(state_bool .processes.udiskie)" = true ]; then start_if_absent '(^|/)(\.udiskie-wrapped|udiskie) --automount --notify$' "$udiskie" --automount --notify || failed=1; fi
  if [ "$(state_bool .processes.clip_persist)" = true ]; then start_if_absent 'wl-clip-persist --clipboard both$' "$wl_clip_persist" --clipboard both || failed=1; fi
  if [ "$(state_bool .processes.wl_paste_text)" = true ]; then start_if_absent 'wl-paste --type text --watch cliphist store$' "$wl_paste" --type text --watch "$cliphist" store || failed=1; fi
  if [ "$(state_bool .processes.wl_paste_image)" = true ]; then start_if_absent 'wl-paste --type image --watch cliphist store$' "$wl_paste" --type image --watch "$cliphist" store || failed=1; fi
  if [ "$(state_bool .processes.loon_launch)" = true ]; then start_if_absent '(^|/)loon-launch$' "$loon_launch" || failed=1; fi
  if [ "$(state_bool .timer_active)" = true ]; then
    "$systemctl" --user start nixos-updates-check.timer >/dev/null 2>&1 || failed=1
  fi
  [ "$failed" -eq 0 ]
}
user_on() {
  init || { err "cannot initialize user state"; return 1; }
  if [ -f "$state_file" ]; then
    valid_state || { err "invalid existing state; use recover"; return 1; }
    [ "$(jq -r .boot_id "$state_file")" = "$(boot_id)" ] || { err "stale state; use recover"; return 1; }
    [ "$(jq -r .phase "$state_file")" = active ] && return 0
    err "state needs recovery"; return 1
  fi
  local state
  state=$(snapshot) || return 1
  save "$state" || { err "cannot save snapshot"; return 1; }
  if ! "$sudo_cmd" "$systemctl" start "$root_unit" >/dev/null 2>&1; then
    "$sudo_cmd" "$systemctl" stop "$root_unit" >/dev/null 2>&1 || true
    rm -f "$state_file"
    err "cannot start fixed root unit"
    return 1
  fi
  if apply_values; then
    phase active
  else
    local rollback_failed=0
    restore_values || rollback_failed=1
    "$sudo_cmd" "$systemctl" stop "$root_unit" >/dev/null 2>&1 || rollback_failed=1
    if [ "$rollback_failed" -eq 0 ]; then rm -f "$state_file"; else phase degraded || true; fi
    err "session operations failed; attempted immediate rollback"
    return 1
  fi
}
user_off() {
  init || { err "cannot initialize user state"; return 1; }
  if [ ! -f "$state_file" ]; then "$sudo_cmd" "$systemctl" stop "$root_unit" >/dev/null 2>&1; return $?; fi
  valid_state || { err "invalid state; refusing session writes"; return 1; }
  if [ "$(jq -r .boot_id "$state_file")" != "$(boot_id)" ]; then
    rm -f "$state_file"
    "$sudo_cmd" "$systemctl" stop "$root_unit" >/dev/null 2>&1
    return $?
  fi
  local failed=0
  phase restoring || true
  restore_values || failed=1
  "$sudo_cmd" "$systemctl" stop "$root_unit" >/dev/null 2>&1 || failed=1
  if [ "$failed" -eq 0 ]; then rm -f "$state_file"; else phase degraded || true; err "restores failed; state retained for recover"; return 1; fi
}
on() { "$systemctl" --user is-active --quiet "$user_unit" >/dev/null 2>&1 && return 0; "$systemctl" --user start "$user_unit"; }
off() {
  if "$systemctl" --user is-active --quiet "$user_unit" >/dev/null 2>&1; then "$systemctl" --user stop "$user_unit"; else user_off; fi
}
status() {
  init || return 1
  [ -f "$state_file" ] || { echo inactive; return 0; }
  valid_state || { echo 'invalid state'; return 1; }
  jq -c '{phase,boot_id,output,mode,brightness,processes,timer_active}' "$state_file"
}
run() {
  on || return 1
  local cleaned=0 rc
  cleanup() { [ "$cleaned" -eq 1 ] && return; cleaned=1; off || true; }
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM HUP
  "$moonlight" "$@"; rc=$?
  cleanup
  trap - INT TERM HUP
  return "$rc"
}

case "${1:-status}" in
  on) on;; off) off;;
  toggle) if "$systemctl" --user is-active --quiet "$user_unit" >/dev/null 2>&1; then off; else on; fi;;
  status) status;; recover) off;; run) shift; run "$@";;
  user-on) user_on;; user-off) user_off;;
  *) echo 'usage: moonlight-power {on|off|toggle|status|recover|run [moonlight args...]}' >&2; exit 2;;
esac
