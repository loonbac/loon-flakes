# Mitad de hardware del perfil automático del Dell Inspiron 15 3520.
# Este paquete solo se activa desde hosts/loon-laptop/power.nix.
# El modo explícito de Moonlight tiene prioridad sobre los eventos AC.
set +e

sysfs=${LAPTOP_POWER_SYSFS_ROOT:-/sys}
procfs=${LAPTOP_POWER_PROCFS_ROOT:-/proc}
moonlight_state=${LAPTOP_POWER_MOONLIGHT_STATE:-/run/moonlight-power/state.json}
state_dir=${LAPTOP_POWER_STATE_DIR:-/run/laptop-power-profile}

err() { echo "laptop-power-profile: $*" >&2; }
read_value() { cat "$1" 2>/dev/null; }
write_checked() {
  local path=$1 value=$2 actual
  printf '%s\n' "$value" > "$path" 2>/dev/null || { err "no se puede escribir $path"; return 1; }
  actual=$(read_value "$path") || return 1
  [ "$actual" = "$value" ] || { err "la verificación de lectura no coincide en $path"; return 1; }
}
write_optional() {
  local path=$1 value=$2
  [ -e "$path" ] || { err "control opcional no disponible: $path"; return 0; }
  write_checked "$path" "$value" || true
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
    grep -qw "$governor" "$policy/scaling_available_governors" 2>/dev/null || { err "gobernador $governor no disponible"; failed=1; continue; }
    grep -qw "$epp" "$policy/energy_performance_available_preferences" 2>/dev/null || { err "EPP $epp no disponible"; failed=1; continue; }
    write_checked "$policy/scaling_governor" "$governor" || failed=1
    write_checked "$policy/energy_performance_preference" "$epp" || failed=1
  done
  grep -qw "$profile" "$sysfs/firmware/acpi/platform_profile_choices" 2>/dev/null || { err "perfil de plataforma $profile no disponible"; failed=1; }
  [ "$failed" -ne 0 ] || write_checked "$sysfs/firmware/acpi/platform_profile" "$profile" || failed=1
  write_checked "$sysfs/devices/system/cpu/intel_pstate/no_turbo" "$turbo" || failed=1
  [ "$failed" -eq 0 ]
}
apply_wifi() {
  local setting=$1 runtime=$2 interface device
  command -v iw >/dev/null 2>&1 || return 0
  while IFS= read -r interface; do
    [ -n "$interface" ] || continue
    iw dev "$interface" link 2>/dev/null | grep -q '^Connected to ' || continue
    iw dev "$interface" set power_save "$setting" >/dev/null 2>&1 || err "no se puede establecer ahorro Wi-Fi $setting en $interface"
    device=$(readlink -f "$sysfs/class/net/$interface/device" 2>/dev/null)
    if [ -n "$device" ] && [ "$(read_value "$device/vendor")" = 0x10ec ] \
      && [ "$(read_value "$device/device")" = 0xc821 ]; then
      write_optional "$device/power/control" "$runtime"
    fi
  done < <(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }')
}
apply_pci_runtime() {
  local bdf=$1 vendor=$2 device=$3 target=$4 path
  path="$sysfs/bus/pci/devices/$bdf"
  [ -d "$path" ] || { err "dispositivo PCI opcional ausente: $bdf"; return 0; }
  if [ "$(read_value "$path/vendor")" != "$vendor" ] || [ "$(read_value "$path/device")" != "$device" ]; then
    err "se rechaza runtime PM para un dispositivo inesperado en $bdf"
    return 0
  fi
  write_optional "$path/power/control" "$target"
}
apply_sata() {
  local profile=$1 runtime=$2 standby=$3 host model standby_state
  for host in "$sysfs"/class/scsi_host/host*; do
    [ -e "$host/link_power_management_policy" ] || continue
    write_optional "$host/link_power_management_policy" "$profile"
  done

  model=$(read_value "$sysfs/block/sda/device/model")
  case "$model" in
    TOSHIBA\ MQ01ABD0*)
      write_optional "$sysfs/block/sda/device/power/control" "$runtime"
      standby_state="$state_dir/hdd-standby"
      if [ "$(read_value "$standby_state")" != "$standby" ]; then
        if hdparm -S "$standby" /dev/sda >/dev/null 2>&1; then
          printf '%s\n' "$standby" > "$standby_state"
        else
          err "no se puede establecer el temporizador de reposo del HDD Toshiba"
        fi
      fi
      ;;
    *) err "no se encontró Toshiba MQ01ABD075 en /dev/sda; se omiten sus controles" ;;
  esac
}
bluetooth_connected() {
  local output
  output=$(bluetoothctl devices Connected 2>/dev/null) || return 2
  [ -n "$output" ]
}
apply_bluetooth() {
  local profile=$1 usb runtime
  if [ "$profile" = battery ]; then
    bluetooth_connected
    case $? in
      0) echo 'laptop-power-profile: Bluetooth permanece activo (hay un dispositivo conectado)' >&2 ;;
      1) rfkill block bluetooth >/dev/null 2>&1 || err "no se puede bloquear Bluetooth inactivo" ;;
      *) err "no se pueden consultar conexiones Bluetooth; se mantiene disponible" ;;
    esac
    runtime=auto
  else
    rfkill unblock bluetooth >/dev/null 2>&1 || err "no se puede desbloquear Bluetooth"
    bluetoothctl power on >/dev/null 2>&1 || true
    runtime=on
  fi

  for usb in "$sysfs"/bus/usb/devices/*; do
    [ "$(read_value "$usb/idVendor")" = 0bda ] || continue
    [ "$(read_value "$usb/idProduct")" = c829 ] || continue
    write_optional "$usb/power/control" "$runtime"
  done
}
apply_misc() {
  local nmi=$1 dirty=$2 audio=$3
  write_optional "$procfs/sys/kernel/nmi_watchdog" "$nmi"
  write_optional "$procfs/sys/vm/dirty_writeback_centisecs" "$dirty"
  write_optional "$sysfs/module/snd_hda_intel/parameters/power_save" "$audio"
}
current_profile() {
  if on_ac; then printf 'ac-rendimiento\n'; else printf 'bateria-ahorro\n'; fi
}
apply_profile() {
  mkdir -p "$state_dir"
  if moonlight_active; then
    echo 'moonlight-prioritario'
    return 0
  fi
  if on_ac; then
    apply_cpu performance performance performance 0 || err "falló al menos un control de CPU en AC"
    apply_wifi off on
    apply_pci_runtime 0000:00:17.0 0x8086 0x51d3 on
    apply_pci_runtime 0000:01:00.0 0x1e0f 0x001b on
    apply_sata max_performance on 0
    apply_bluetooth ac
    apply_misc 1 500 0
    echo 'ac-rendimiento'
  else
    apply_cpu powersave power quiet 1 || err "falló al menos un control de CPU en batería"
    apply_wifi on auto
    apply_pci_runtime 0000:00:17.0 0x8086 0x51d3 auto
    # APST sigue gestionado por el kernel; solo se permite runtime PM PCI.
    apply_pci_runtime 0000:01:00.0 0x1e0f 0x001b auto
    # Por debajo de 241 cada unidad equivale a 5 segundos: 180 son 15 minutos,
    # un valor conservador para evitar ciclos repetidos del HDD Toshiba.
    apply_sata med_power_with_dipm auto 180
    apply_bluetooth battery
    apply_misc 0 1500 1
    echo 'bateria-ahorro'
  fi
}

case "${1:-apply}" in
  apply) apply_profile ;;
  status) current_profile ;;
  *) echo 'uso: laptop-power-profile {apply|status}' >&2; exit 2 ;;
esac
