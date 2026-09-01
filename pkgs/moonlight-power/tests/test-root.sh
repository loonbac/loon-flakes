#!/usr/bin/env bash
# The root helper is exercised against a fake sysfs tree.  This verifies its
# snapshot, fixed writes, readback, and exact rollback without root access.
set -euo pipefail

root_helper="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
sys="$tmp/sys"
state="$tmp/state"
mkdir -p "$bin" "$sys/devices/system/cpu/cpufreq/policy0" \
  "$sys/devices/system/cpu/intel_pstate" "$sys/firmware/acpi" \
  "$sys/class/net/wlp0s20f3"

printf '%s\n' performance > "$sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
printf '%s\n' balance_performance > "$sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference"
printf '%s\n' balanced > "$sys/firmware/acpi/platform_profile"
printf '%s\n' 'quiet [balanced] performance' > "$sys/firmware/acpi/platform_profile_choices"
printf '%s\n' 0 > "$sys/devices/system/cpu/intel_pstate/no_turbo"
printf '%s\n' on > "$tmp/wifi-power-save"

printf '#!%s\n%s\n' "$BASH" 'printf "%s\n" "wlp0s20f3:wifi:connected"' > "$bin/nmcli"
{
printf '#!%s\n' "$BASH"
cat <<'EOF'
set -eu
state=${MOONLIGHT_POWER_FAKE_WIFI_STATE:?}
case "$*" in
  "dev wlp0s20f3 get power_save") printf 'Power save: %s\n' "$(cat "$state")" ;;
  "dev wlp0s20f3 set power_save on") printf 'on\n' > "$state" ;;
  "dev wlp0s20f3 set power_save off") printf 'off\n' > "$state" ;;
  *) exit 2 ;;
esac
EOF
} > "$bin/iw"
chmod +x "$bin/nmcli" "$bin/iw"
invoke_root() {
  if [ -n "${MOONLIGHT_POWER_TEST_SHELL:-}" ]; then
    "$MOONLIGHT_POWER_TEST_SHELL" "$root_helper" "$@"
  else
    "$root_helper" "$@"
  fi
}

MOONLIGHT_POWER_TESTING=1 MOONLIGHT_POWER_TEST_BIN_DIR="$bin" \
MOONLIGHT_POWER_SYSFS_ROOT="$sys" MOONLIGHT_POWER_ROOT_STATE_DIR="$state" \
MOONLIGHT_POWER_FAKE_WIFI_STATE="$tmp/wifi-power-save" \
  invoke_root apply

test "$(< "$sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" = powersave
test "$(< "$sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference")" = power
test "$(< "$sys/firmware/acpi/platform_profile")" = quiet
test "$(< "$sys/devices/system/cpu/intel_pstate/no_turbo")" = 1
test "$(< "$tmp/wifi-power-save")" = off
test "$(jq -r .phase "$state/state.json")" = active

MOONLIGHT_POWER_TESTING=1 MOONLIGHT_POWER_TEST_BIN_DIR="$bin" \
MOONLIGHT_POWER_SYSFS_ROOT="$sys" MOONLIGHT_POWER_ROOT_STATE_DIR="$state" \
MOONLIGHT_POWER_FAKE_WIFI_STATE="$tmp/wifi-power-save" \
  invoke_root restore

test "$(< "$sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" = performance
test "$(< "$sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference")" = balance_performance
test "$(< "$sys/firmware/acpi/platform_profile")" = balanced
test "$(< "$sys/devices/system/cpu/intel_pstate/no_turbo")" = 0
test "$(< "$tmp/wifi-power-save")" = on
test ! -e "$state/state.json"
