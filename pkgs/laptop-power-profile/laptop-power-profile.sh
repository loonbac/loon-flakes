# Automatically select the machine-wide profile from the current power source.
# Moonlight's explicit low-power mode has priority over automatic AC events.
set +e

sysfs=${LAPTOP_POWER_SYSFS_ROOT:-/sys}
moonlight_state=${LAPTOP_POWER_MOONLIGHT_STATE:-/run/moonlight-power/state.json}

err() { echo "laptop-power-profile: $*" >&2; }
read_value() { cat "$1" 2>/dev/null; }
write_checked() {
  local path=$1 value=$2 actual
  printf '%s\n' "$value" > "$path" 2>/dev/null || { err "cannot write $path"; return 1; }
  actual=$(read_value "$path") || return 1
  [ "$actual" = "$value" ] || { err "readback mismatch for $path"; return 1; }
}
on_ac() {
  local supply type online
  for supply in "$sysfs"/class/power_supply/*; do
    [ -d "$supply" ] || continue
    type=$(read_value "$supply/type") || continue
    [ "$type" = Mains ] || continue
    online=$(read_value "$supply/online") || continue
    [ "$online" = 1 ] && return 0
  done
  return 1
}
moonlight_active() {
  [ -f "$moonlight_state" ] || return 1
  grep -Eq '"phase"[[:space:]]*:[[:space:]]*"(snapshot|active|restoring|degraded)"' "$moonlight_state"
}
apply_cpu() {
  local governor=$1 epp=$2 profile=$3 turbo=$4 failed=0 policy
  for policy in "$sysfs"/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    grep -qw "$governor" "$policy/scaling_available_governors" 2>/dev/null || { err "$governor governor unavailable"; failed=1; continue; }
    grep -qw "$epp" "$policy/energy_performance_available_preferences" 2>/dev/null || { err "$epp EPP unavailable"; failed=1; continue; }
    write_checked "$policy/scaling_governor" "$governor" || failed=1
    write_checked "$policy/energy_performance_preference" "$epp" || failed=1
  done
  grep -qw "$profile" "$sysfs/firmware/acpi/platform_profile_choices" 2>/dev/null || { err "$profile platform profile unavailable"; failed=1; }
  [ "$failed" -ne 0 ] || write_checked "$sysfs/firmware/acpi/platform_profile" "$profile" || failed=1
  write_checked "$sysfs/devices/system/cpu/intel_pstate/no_turbo" "$turbo" || failed=1
  [ "$failed" -eq 0 ]
}
apply_wifi() {
  local setting=$1 interface
  command -v iw >/dev/null 2>&1 || return 0
  while IFS= read -r interface; do
    [ -n "$interface" ] || continue
    iw dev "$interface" link 2>/dev/null | grep -q '^Connected to ' || continue
    iw dev "$interface" set power_save "$setting" >/dev/null 2>&1 || err "cannot set Wi-Fi power-save $setting on $interface"
  done < <(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }')
}
current_profile() {
  if on_ac; then printf 'ac-performance\n'; else printf 'battery-saver\n'; fi
}
apply_profile() {
  # Dell adapters can emit a short offline/online burst while negotiating.
  # Read the settled value, and let a newer ACPI event restart this helper.
  sleep "${LAPTOP_POWER_SETTLE_SECONDS:-1}"
  if moonlight_active; then
    echo 'moonlight-override'
    return 0
  fi
  if on_ac; then
    apply_cpu performance performance performance 0 || return 1
    apply_wifi off
    echo 'ac-performance'
  else
    apply_cpu powersave power quiet 1 || return 1
    apply_wifi on
    echo 'battery-saver'
  fi
}

case "${1:-apply}" in
  apply) apply_profile ;;
  status) current_profile ;;
  *) echo 'usage: laptop-power-profile {apply|status}' >&2; exit 2 ;;
esac
