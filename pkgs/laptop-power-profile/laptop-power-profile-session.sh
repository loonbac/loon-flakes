# Mitad de sesión de usuario del perfil automático de loon-laptop.
# Solo cambia el modo del panel eDP-1 y la pausa de mpvpaper.
set +e

sysfs=${LAPTOP_POWER_SYSFS_ROOT:-/sys}
moonlight_root_state=${LAPTOP_POWER_MOONLIGHT_STATE:-/run/moonlight-power/state.json}
moonlight_user_state=${LAPTOP_POWER_MOONLIGHT_USER_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/moonlight-power/state.json}

err() { echo "laptop-power-profile-session: $*" >&2; }
read_value() { cat "$1" 2>/dev/null; }
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
moonlight_active_file() {
  [ -f "$1" ] || return 1
  grep -Eq '"phase"[[:space:]]*:[[:space:]]*"(snapshot|active|restoring|degraded)"' "$1"
}
moonlight_active() {
  moonlight_active_file "$moonlight_root_state" || moonlight_active_file "$moonlight_user_state"
}
outputs_json() { niri msg -j outputs 2>/dev/null; }
target_mode() {
  local minimum=$1 maximum=$2
  outputs_json | jq -r --argjson minimum "$minimum" --argjson maximum "$maximum" '
    ."eDP-1"? // empty
    | .modes[]?
    | select(.width == 1920 and .height == 1080)
    | select(.refresh_rate >= $minimum and .refresh_rate <= $maximum)
    | "\(.width)x\(.height)@\(.refresh_rate / 1000)"
  ' | head -n1
}
current_mode() {
  outputs_json | jq -r '
    ."eDP-1"? // empty
    | select(.current_mode != null)
    | .modes[.current_mode]
    | "\(.width)x\(.height)@\(.refresh_rate / 1000)"
  '
}
set_display_mode() {
  local minimum=$1 maximum=$2 target actual
  if ! outputs_json | jq -e 'has("eDP-1")' >/dev/null 2>&1; then
    err "eDP-1 no está disponible; las salidas quedan sin cambios"
    return 0
  fi
  target=$(target_mode "$minimum" "$maximum")
  if [ -z "$target" ]; then
    err "eDP-1 no anuncia el rango de refresco 1920x1080 solicitado"
    return 0
  fi
  actual=$(current_mode)
  # Los adaptadores Dell pueden repetir eventos sin cambiar realmente de
  # fuente. Evitar un atomic commit idéntico reduce trabajo DRM/i915.
  [ "$actual" = "$target" ] && return 0
  niri msg output eDP-1 mode "$target" >/dev/null 2>&1 \
    || { err "niri rechazó el modo $target en eDP-1"; return 0; }
  actual=$(current_mode)
  [ "$actual" = "$target" ] || err "verificación de pantalla: se pidió $target y se obtuvo ${actual:-desconocido}"
}
apply_profile() {
  local wallpaper
  if moonlight_active; then
    echo moonlight-prioritario
    return 0
  fi
  if on_ac; then
    set_display_mode 119000 121000
    wallpaper=$(mpvpaper-wallpaper status 2>/dev/null)
    [ "$wallpaper" = paused ] && mpvpaper-wallpaper resume >/dev/null 2>&1 || true
    echo ac-rendimiento
  else
    set_display_mode 59000 61000
    wallpaper=$(mpvpaper-wallpaper status 2>/dev/null)
    [ "$wallpaper" = playing ] && mpvpaper-wallpaper pause >/dev/null 2>&1 || true
    echo bateria-ahorro
  fi
}
status() {
  local profile mode wallpaper
  if on_ac; then profile=ac-rendimiento; else profile=bateria-ahorro; fi
  mode=$(current_mode)
  wallpaper=$(mpvpaper-wallpaper status 2>/dev/null)
  printf 'perfil=%s salida=eDP-1 modo=%s fondo=%s\n' \
    "$profile" "${mode:-no-disponible}" "${wallpaper:-no-disponible}"
}

case "${1:-apply}" in
  apply) apply_profile ;;
  status) status ;;
  *) echo 'uso: laptop-power-profile-session {apply|status}' >&2; exit 2 ;;
esac
