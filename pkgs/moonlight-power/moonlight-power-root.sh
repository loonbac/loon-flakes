# Fixed root-only operations.  State is JSON, atomically renamed, and every
# parsed value is validated before it can reach a sysfs write.
set +e

state_dir=/run/moonlight-power
sysfs=/sys
if [ "${MOONLIGHT_POWER_TESTING:-0}" = 1 ]; then
  # The systemd unit pins this variable to 0.  This branch exists solely for
  # package tests running unprivileged against a fake sysfs tree.
  state_dir=${MOONLIGHT_POWER_ROOT_STATE_DIR:?missing test state directory}
  sysfs=${MOONLIGHT_POWER_SYSFS_ROOT:?missing test sysfs directory}
  nmcli=${MOONLIGHT_POWER_TEST_BIN_DIR:?missing test bin}/nmcli
  iw=${MOONLIGHT_POWER_TEST_BIN_DIR:?missing test bin}/iw
else
  nmcli=nmcli
  iw=iw
fi
state_file=$state_dir/state.json
lock_file=$state_dir/lock

err() { echo "moonlight-power-root: $*" >&2; return 1; }
token() { case "${1:-}" in ""|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
boot_id() {
  local id
  id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
  printf '%s\n' "$id" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
  printf '%s\n' "$id"
}
line() { cat "$1" 2>/dev/null; }
write_checked() {
  local path=$1 value=$2 readback
  printf '%s\n' "$value" > "$path" 2>/dev/null || { err "cannot write $path"; return 1; }
  readback=$(line "$path") || return 1
  [ "$readback" = "$value" ] || { err "readback mismatch for $path"; return 1; }
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
    and (.cpu | type == "array" and length > 0 and all(.[]; type == "object"
      and (.policy | type == "string" and test("^policy[0-9]+$"))
      and (.governor | type == "string" and test("^[A-Za-z0-9._-]+$"))
      and (.epp | type == "string" and test("^[A-Za-z0-9._-]+$"))))
    and (.platform | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and (.turbo | type == "string" and test("^[01]$"))
    and (.wifi | type == "object"
      and (.interface | type == "string" and test("^[A-Za-z0-9._-]+$"))
      and (.power_save == "on" or .power_save == "off"))
  ' "$state_file" >/dev/null 2>&1
}
phase() {
  local payload
  payload=$(jq -ce --arg phase "$1" '.phase = $phase' "$state_file") || return 1
  save "$payload"
}
active_wifi() {
  local interface
  interface=$("$nmcli" --terse --fields DEVICE,TYPE,STATE device 2>/dev/null | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
  token "$interface" && [ -d "$sysfs/class/net/$interface" ] || return 1
  printf '%s\n' "$interface"
}
wifi_power_get() {
  local interface=$1 value
  token "$interface" || return 1
  value=$("$iw" dev "$interface" get power_save 2>/dev/null | awk -F': *' '/^Power save:/ {print $2; exit}') || return 1
  { [ "$value" = on ] || [ "$value" = off ]; } || return 1
  printf '%s\n' "$value"
}
wifi_power_set() {
  local interface=$1 value=$2
  token "$interface" && { [ "$value" = on ] || [ "$value" = off ]; } || return 1
  "$iw" dev "$interface" set power_save "$value" >/dev/null 2>&1 || return 1
  [ "$(wifi_power_get "$interface")" = "$value" ] || { err "Wi-Fi power-save readback mismatch"; return 1; }
}
snapshot() {
  local boot platform turbo wifi power policy policy_name governor epp cpu='[]'
  boot=$(boot_id) || { err "cannot read boot ID"; return 1; }
  [ -f "$sysfs/firmware/acpi/platform_profile" ] || { err "platform profile is unavailable"; return 1; }
  [ -f "$sysfs/devices/system/cpu/intel_pstate/no_turbo" ] || { err "turbo control is unavailable"; return 1; }
  [ -f "$sysfs/firmware/acpi/platform_profile_choices" ] && ! grep -qw quiet "$sysfs/firmware/acpi/platform_profile_choices" && {
    err "quiet platform profile is unavailable"; return 1;
  }
  platform=$(line "$sysfs/firmware/acpi/platform_profile") || return 1
  turbo=$(line "$sysfs/devices/system/cpu/intel_pstate/no_turbo") || return 1
  if ! token "$platform" || { [ "$turbo" != 0 ] && [ "$turbo" != 1 ]; }; then
    err "invalid platform state"
    return 1
  fi
  for policy in "$sysfs"/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    [ -f "$policy/scaling_governor" ] && [ -f "$policy/energy_performance_preference" ] || { err "incomplete CPU policy"; return 1; }
    governor=$(line "$policy/scaling_governor") || return 1
    epp=$(line "$policy/energy_performance_preference") || return 1
    policy_name=${policy##*/}
    printf '%s\n' "$policy_name" | grep -Eq '^policy[0-9]+$' || { err "invalid CPU policy name"; return 1; }
    if ! token "$governor" || ! token "$epp"; then err "invalid CPU policy state"; return 1; fi
    cpu=$(printf '%s' "$cpu" | jq -ce --arg policy "$policy_name" --arg governor "$governor" --arg epp "$epp" '. + [{policy:$policy,governor:$governor,epp:$epp}]') || return 1
  done
  [ "$cpu" != '[]' ] || { err "no CPU policies found"; return 1; }
  wifi=$(active_wifi) || { err "no active Wi-Fi interface with power_save"; return 1; }
  power=$(wifi_power_get "$wifi") || { err "cannot read Wi-Fi power-save state"; return 1; }
  jq -cn --arg boot_id "$boot" --argjson cpu "$cpu" --arg platform "$platform" --arg turbo "$turbo" --arg interface "$wifi" --arg power_save "$power" \
    '{version:1,boot_id:$boot_id,phase:"snapshot",cpu:$cpu,platform:$platform,turbo:$turbo,wifi:{interface:$interface,power_save:$power_save}}'
}
apply_values() {
  local failed=0 policy policy_name wifi
  while IFS= read -r policy_name; do
    printf '%s\n' "$policy_name" | grep -Eq '^policy[0-9]+$' || { failed=1; continue; }
    policy="$sysfs/devices/system/cpu/cpufreq/$policy_name"
    [ -d "$policy" ] || { failed=1; continue; }
    write_checked "$policy/scaling_governor" powersave || failed=1
    write_checked "$policy/energy_performance_preference" power || failed=1
  done < <(jq -r '.cpu[].policy' "$state_file")
  write_checked "$sysfs/firmware/acpi/platform_profile" quiet || failed=1
  write_checked "$sysfs/devices/system/cpu/intel_pstate/no_turbo" 1 || failed=1
  wifi=$(jq -r '.wifi.interface' "$state_file") || failed=1
  token "$wifi" && wifi_power_set "$wifi" off || failed=1
  [ "$failed" -eq 0 ]
}
restore_values() {
  # Policy names are strictly validated before building fixed sysfs paths.
  local failed=0 index=0 policy policy_name governor epp platform turbo wifi power count
  count=$(jq -r '.cpu | length' "$state_file") || return 1
  while [ "$index" -lt "$count" ]; do
    policy_name=$(jq -r ".cpu[$index].policy" "$state_file") || failed=1
    printf '%s\n' "$policy_name" | grep -Eq '^policy[0-9]+$' || { failed=1; index=$((index + 1)); continue; }
    policy="$sysfs/devices/system/cpu/cpufreq/$policy_name"
    [ -d "$policy" ] || { failed=1; index=$((index + 1)); continue; }
    governor=$(jq -r ".cpu[$index].governor" "$state_file") || failed=1
    epp=$(jq -r ".cpu[$index].epp" "$state_file") || failed=1
    token "$governor" && write_checked "$policy/scaling_governor" "$governor" || failed=1
    token "$epp" && write_checked "$policy/energy_performance_preference" "$epp" || failed=1
    index=$((index + 1))
  done
  platform=$(jq -r '.platform' "$state_file") || failed=1
  turbo=$(jq -r '.turbo' "$state_file") || failed=1
  wifi=$(jq -r '.wifi.interface' "$state_file") || failed=1
  power=$(jq -r '.wifi.power_save' "$state_file") || failed=1
  token "$platform" && write_checked "$sysfs/firmware/acpi/platform_profile" "$platform" || failed=1
  { [ "$turbo" = 0 ] || [ "$turbo" = 1 ]; } && write_checked "$sysfs/devices/system/cpu/intel_pstate/no_turbo" "$turbo" || failed=1
  token "$wifi" && { [ "$power" = on ] || [ "$power" = off ]; } && wifi_power_set "$wifi" "$power" || failed=1
  [ "$failed" -eq 0 ]
}
apply() {
  init || { err "cannot initialize protected state"; return 1; }
  if [ -f "$state_file" ]; then
    valid_state || { err "invalid existing state; use recover"; return 1; }
    [ "$(jq -r .boot_id "$state_file")" = "$(boot_id)" ] || { err "stale state; use recover"; return 1; }
    [ "$(jq -r .phase "$state_file")" = active ] && return 0
    err "state needs recovery"; return 1
  fi
  local state
  state=$(snapshot) || return 1
  save "$state" || { err "cannot save snapshot"; return 1; }
  if apply_values; then
    phase active
  else
    if restore_values; then rm -f "$state_file"; else phase degraded || true; fi
    err "operations failed; attempted immediate rollback"
    return 1
  fi
}
restore() {
  init || return 1
  [ -f "$state_file" ] || return 0
  valid_state || { err "invalid state; refusing writes"; return 1; }
  [ "$(jq -r .boot_id "$state_file")" = "$(boot_id)" ] || { err "stale state; use recover"; return 1; }
  phase restoring || true
  if restore_values; then rm -f "$state_file"; else phase degraded || true; err "restores failed; state retained for recovery"; return 1; fi
}
recover() {
  init || return 1
  [ -f "$state_file" ] || return 0
  valid_state || { err "invalid state; refusing writes"; return 1; }
  if [ "$(jq -r .boot_id "$state_file")" != "$(boot_id)" ]; then
    rm -f "$state_file"
    return 0
  fi
  phase restoring || true
  if restore_values; then rm -f "$state_file"; else phase degraded || true; err "recovery failed; state retained"; return 1; fi
}
status() {
  init || return 1
  [ -f "$state_file" ] || { echo inactive; return 0; }
  valid_state || { echo 'invalid state'; return 1; }
  jq -c '{phase,boot_id,cpu,platform,turbo,wifi}' "$state_file"
}

case "${1:-status}" in
  apply) apply;; restore) restore;; recover) recover;; status) status;;
  *) echo 'usage: moonlight-power-root {apply|restore|recover|status}' >&2; exit 2;;
esac
