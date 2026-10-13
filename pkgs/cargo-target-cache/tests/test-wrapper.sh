#!/usr/bin/env bash
# Pruebas enfocadas del wrapper `cargo` de pkgs/cargo-target-cache.
#
# El wrapper se ejercita contra un `cargo` falso que resuelve `locate-project`
# como lo hace cargo real (raíz del workspace si el directorio actual está
# dentro de él) y, en cualquier otro caso, publica el entorno con el que fue
# invocado. Así se verifica el mapeo al caché, la conservación del
# comportamiento original y la propagación del código de salida, sin red ni
# cambios en el sistema.
#
# Uso: test-wrapper.sh <ruta al wrapper cargo>
set -euo pipefail

wrapper="$1"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cache="$tmp/cache"
workspace="$tmp/work/space"
mkdir -p "$cache" "$workspace/member/deep" "$tmp/bin"

# ---------------------------------------------------------------- cargo falso
stub="$tmp/bin/cargo"
{
  printf '#!%s\n' "$BASH"
  cat <<'STUB'
set -euo pipefail

if [ "${1:-}" = "locate-project" ]; then
  manifest=""
  previous=""
  for argument in "$@"; do
    case "$previous" in
      --manifest-path) manifest="$argument" ;;
    esac
    case "$argument" in
      --manifest-path=*) manifest="${argument#--manifest-path=}" ;;
    esac
    previous="$argument"
  done
  if [ -z "$manifest" ]; then
    case "${PWD:-}" in
      "${STUB_WORKSPACE_ROOT:?}"*) manifest="$STUB_WORKSPACE_ROOT/Cargo.toml" ;;
      *) printf 'error: could not find `Cargo.toml` in `%s`\n' "$PWD" >&2; exit 101 ;;
    esac
  fi
  printf '%s\n' "$manifest"
  exit 0
fi

printf 'target_dir=%s\n' "${CARGO_TARGET_DIR:-<unset>}"
printf 'args=%s\n' "$*"
exit "${STUB_EXIT_CODE:-0}"
STUB
} >"$stub"
chmod +x "$stub"

# ------------------------------------------------------------------ utilidades
out="$tmp/stdout"
err="$tmp/stderr"
status=0
failures=0

declare -a extra_env=()
# cargo real a usar: vacío = el que el wrapper lleva embebido (store path).
real_cargo="$stub"

run_wrapper() {
  local cwd="$1"
  shift
  local -a environment=(
    "STUB_WORKSPACE_ROOT=$workspace"
    "CARGO_TARGET_CACHE_ROOT=$cache"
  )
  if [ -n "$real_cargo" ]; then
    environment+=("CARGO_TARGET_CACHE_REAL_CARGO=$real_cargo")
  fi
  if [ "${#extra_env[@]}" -gt 0 ]; then
    environment+=("${extra_env[@]}")
  fi
  set +e
  ( cd "$cwd" && env "${environment[@]}" "$wrapper" "$@" ) >"$out" 2>"$err"
  status=$?
  set -e
}

reset_env() {
  extra_env=()
  real_cargo="$stub"
}

ok() {
  printf 'ok      %s\n' "$1"
}

ko() {
  printf 'FALLO   %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (esperado '$2', obtenido '$3')"; fi
}

assert_contains() {
  if grep -qF -- "$2" "$3"; then ok "$1"; else ko "$1 (no aparece '$2' en $3)"; fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$3"; then ko "$1 (aparece '$2' en $3)"; else ok "$1"; fi
}

# Valor de CARGO_TARGET_DIR que vio el cargo falso en la última ejecución.
observed_target_dir() {
  sed -n 's/^target_dir=//p' "$out"
}

# Subdirectorios presentes en el caché (cada workspace mapeado ocupa uno).
cache_entries() {
  find "$cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
}

# ---------------------------------------------------- R1: mapeo desde la raíz
run_wrapper "$workspace" build
assert_eq "R1 el wrapper conserva el código de salida de cargo" "0" "$status"
root_target="$(observed_target_dir)"
case "$root_target" in
  "$cache"/*) ok "R1 CARGO_TARGET_DIR apunta a un hijo directo del caché" ;;
  *) ko "R1 CARGO_TARGET_DIR no apunta al caché (obtenido '$root_target')" ;;
esac
assert_eq "R1 se crea el directorio de artefactos" "1" "$(test -d "$root_target" && echo 1 || echo 0)"
assert_eq \
  "R1 el mapeo queda documentado en .workspace-path" \
  "$workspace" \
  "$(cat "$root_target/.workspace-path" 2>/dev/null || echo '<sin archivo>')"
assert_eq "R1 no se crea target/ dentro del workspace" "1" \
  "$(test -d "$workspace/target" && echo 0 || echo 1)"

# ----------------------------------------- R2: mismo mapeo desde subdirectorio
run_wrapper "$workspace/member/deep" build
assert_eq \
  "R2 un subdirectorio del workspace reutiliza el mismo caché" \
  "$root_target" "$(observed_target_dir)"
assert_eq "R2 el caché sigue teniendo una sola entrada" "1" "$(cache_entries)"

# --------------------------------------- R3/R4: --manifest-path desde afuera
run_wrapper "$tmp" build --manifest-path "$workspace/Cargo.toml"
assert_eq \
  "R3 --manifest-path resuelve al mismo caché" \
  "$root_target" "$(observed_target_dir)"

run_wrapper "$tmp" build "--manifest-path=$workspace/Cargo.toml"
assert_eq \
  "R4 --manifest-path= (forma con igual) resuelve al mismo caché" \
  "$root_target" "$(observed_target_dir)"
assert_eq "R4 los dos --manifest-path comparten una sola entrada" "1" "$(cache_entries)"

# ------------------------------------------- R5: fuera de un proyecto cargo
entries_before="$(cache_entries)"
run_wrapper "$tmp" --version
assert_eq "R5 fuera de un proyecto no se define CARGO_TARGET_DIR" "<unset>" "$(observed_target_dir)"
assert_eq "R5 fuera de un proyecto no se crea nada en el caché" "$entries_before" "$(cache_entries)"

# ------------------------------- R6: CARGO_TARGET_DIR propio de quien invoca
run_wrapper "$workspace" build
extra_env=("CARGO_TARGET_DIR=$tmp/elegido-por-el-usuario")
run_wrapper "$workspace" build
assert_eq "R6 se respeta el CARGO_TARGET_DIR del usuario" "$tmp/elegido-por-el-usuario" "$(observed_target_dir)"
reset_env

# --------------------------------- R7: argumentos intactos y código de salida
extra_env=("STUB_EXIT_CODE=42")
run_wrapper "$workspace" test --release --features uno,dos -- --nocapture
assert_eq "R7 se propaga el código de salida de cargo" "42" "$status"
assert_eq \
  "R7 se propagan los argumentos sin alterarlos" \
  "args=test --release --features uno,dos -- --nocapture" \
  "$(sed -n '2p' "$out")"
reset_env

# -------------------------------- R8: dos workspaces distintos no colisionan
other="$tmp/work/otro-espacio/space"
mkdir -p "$other"
workspace="$other"
run_wrapper "$other" build
other_target="$(observed_target_dir)"
assert_eq "R8 un segundo workspace usa otra entrada del caché" "2" "$(cache_entries)"
if [ "$other_target" != "$root_target" ]; then
  ok "R8 los dos workspace no comparten directorio"
else
  ko "R8 los dos workspace comparten directorio ('$other_target')"
fi
assert_eq \
  "R8 el segundo mapeo queda documentado" \
  "$other" \
  "$(cat "$other_target/.workspace-path" 2>/dev/null || echo '<sin archivo>')"
workspace="$tmp/work/space"

# ----------------------------- R9: ruta larga (nombre de directorio acotado)
long_workspace="$tmp/work/$(printf 'x%.0s' {1..90})/$(printf 'y%.0s' {1..90})"
mkdir -p "$long_workspace"
extra_env=("CARGO_TARGET_CACHE_ROOT=$tmp/cache-largo")
workspace="$long_workspace"
run_wrapper "$long_workspace" build
first_long="$(observed_target_dir)"
assert_eq "R9 una ruta larga produce un solo componente bajo el caché" "1" \
  "$(find "$tmp/cache-largo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
run_wrapper "$long_workspace" build
assert_eq "R9 la clave larga es estable entre invocaciones" "$first_long" "$(observed_target_dir)"
workspace="$tmp/work/space"
reset_env

# --------------------------- R10: caché no escribible (degradación explícita)
readonly_cache="$tmp/cache-solo-lectura"
mkdir -p "$readonly_cache"
chmod 0555 "$readonly_cache"
extra_env=("CARGO_TARGET_CACHE_ROOT=$readonly_cache")
run_wrapper "$workspace" build
assert_eq "R10 sin caché escribible cargo se ejecuta igual" "0" "$status"
assert_eq "R10 sin caché escribible no se define CARGO_TARGET_DIR" "<unset>" "$(observed_target_dir)"
assert_contains "R10 se avisa del caché no escribible" "aviso: no se pudo preparar" "$err"
reset_env

# ---------------------- R11: el cargo real embebido sigue funcionando intacto
real_cargo=""
entries_before="$(cache_entries)"
run_wrapper "$tmp" --version
assert_eq "R11 --version a través del wrapper funciona con el cargo real" "0" "$status"
assert_contains "R11 se informa la versión de cargo" "cargo 1" "$out"
assert_eq "R11 --version no crea entradas en el caché" "$entries_before" "$(cache_entries)"
reset_env

# -------------- R12: caché existente pero no escribible (hallazgo R3)
write_cache="$tmp/cache-no-escribible"
extra_env=("CARGO_TARGET_CACHE_ROOT=$write_cache")
run_wrapper "$workspace" build
entry_dir="$(observed_target_dir)"
rm -f "$entry_dir/.workspace-path"
chmod 0555 "$entry_dir"
run_wrapper "$workspace" build
assert_eq "R12 un caché existente no escribible no rompe el wrapper" "0" "$status"
assert_eq "R12 se degrada al comportamiento original" "<unset>" "$(observed_target_dir)"
assert_contains "R12 se avisa del caché no preparable" "aviso: no se pudo preparar" "$err"
chmod 0755 "$entry_dir"
reset_env

# ------------- R13: el marcador existe pero no es escribible (R3, otra forma)
ro_marker_cache="$tmp/cache-marcador-0444"
extra_env=("CARGO_TARGET_CACHE_ROOT=$ro_marker_cache")
run_wrapper "$workspace" build
ro_marker_entry="$(observed_target_dir)"
chmod 0444 "$ro_marker_entry/.workspace-path"
run_wrapper "$workspace" build
assert_eq "R13 un marcador no escribible no rompe el wrapper" "0" "$status"
assert_eq "R13 se degrada al comportamiento original" "<unset>" "$(observed_target_dir)"
chmod 0644 "$ro_marker_entry/.workspace-path"
reset_env

# ---------- R14: la ruta de la entrada existe como archivo, no como directorio
file_entry_cache="$tmp/cache-entrada-archivo"
extra_env=("CARGO_TARGET_CACHE_ROOT=$file_entry_cache")
run_wrapper "$workspace" build
file_entry="$(observed_target_dir)"
rm -rf "$file_entry"
printf 'no soy un directorio\n' >"$file_entry"
run_wrapper "$workspace" build
assert_eq "R14 una entrada que es archivo no rompe el wrapper" "0" "$status"
assert_eq "R14 se degrada al comportamiento original" "<unset>" "$(observed_target_dir)"
assert_contains "R14 se avisa del caché no preparable" "aviso: no se pudo preparar" "$err"
rm -f "$file_entry"
reset_env

# ---------------------------------------------------------------- resultado
if [ "$failures" -gt 0 ]; then
  printf '\n%d prueba(s) fallida(s)\n' "$failures" >&2
  exit 1
fi
printf '\ntodas las pruebas del wrapper cargo pasaron\n'
