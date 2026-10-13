#!/usr/bin/env bash
# Wrapper de `cargo` que mueve el directorio de artefactos (`target/`) fuera del
# árbol de trabajo, a un caché por workspace en el disco raíz.
#
# Por qué: `target/` es salida descartable del compilador y puede pesar decenas
# de GB (debuginfo incluido), llenando la partición donde vive el código.
#
# Reglas (cubiertas por tests/test-wrapper.sh):
#   1. El destino se deriva del *workspace root* real (`cargo locate-project`),
#      no de $PWD: invocar cargo desde un subdirectorio no crea otra entrada.
#   2. Fuera de un proyecto Cargo no se define CARGO_TARGET_DIR: el
#      comportamiento original queda intacto.
#   3. Si CARGO_TARGET_DIR ya viene definido por quien invoca, se respeta.
#   4. Los argumentos y el código de salida se propagan sin alterarlos.
#   5. Si el caché no se puede crear, se avisa y se compila como antes.
#
# Ajustes por entorno:
#   CARGO_TARGET_CACHE_ROOT             raíz del caché (por defecto @cacheRoot@)
#   CARGO_TARGET_CACHE_REAL_CARGO       binario de cargo a ejecutar (pruebas)
#   CARGO_TARGET_CACHE_PRINT_TARGET_DIR =1 imprime el destino y no compila
set -euo pipefail

real_cargo="${CARGO_TARGET_CACHE_REAL_CARGO:-@realCargo@}"
cache_root="${CARGO_TARGET_CACHE_ROOT:-@cacheRoot@}"

# Regla 3: la intención explícita de quien invoca gana.
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
  exec "$real_cargo" "$@"
fi

# `--manifest-path` puede llegar como "--manifest-path X" o "--manifest-path=X".
manifest_path=""
previous=""
for argument in "$@"; do
  case "$previous" in
    --manifest-path) manifest_path="$argument" ;;
  esac
  case "$argument" in
    --manifest-path=*) manifest_path="${argument#--manifest-path=}" ;;
  esac
  previous="$argument"
done

locate_arguments=()
if [ -n "$manifest_path" ]; then
  locate_arguments=(--manifest-path "$manifest_path")
fi

# Regla 1: la raíz del workspace es la clave estable del caché. Su ausencia
# (fuera de un proyecto) no es un error del wrapper.
workspace_manifest=""
workspace_manifest="$("$real_cargo" locate-project --workspace --message-format plain \
  "${locate_arguments[@]}" 2>/dev/null)" || workspace_manifest=""

# Regla 2.
if [ -z "$workspace_manifest" ]; then
  exec "$real_cargo" "$@"
fi

workspace_root="${workspace_manifest%/*}"

# Clave legible y estable: la ruta absoluta con los caracteres que no son
# seguros en un nombre de archivo convertidos en guiones. Dos rutas que solo
# difieran en `/` y `-` compartirían entrada; el efecto es el mismo que
# compartir target dir entre worktrees del mismo repo (cargo separa los
# artefactos por contenido, no por ruta).
cache_key="${workspace_root#/}"
cache_key="$(printf '%s' "$cache_key" | tr -c 'A-Za-z0-9._-' '-')"
# Un componente de ruta no puede pasar de 255 bytes: con rutas muy largas se
# usa un hash estable de la ruta completa.
if [ "${#cache_key}" -gt 180 ]; then
  cache_key="workspace-$(printf '%s' "$workspace_root" | cksum | cut -d' ' -f1)"
fi

target_dir="$cache_root/$cache_key"

# Regla 5: un caché no escribible no puede impedir compilar.
# El directorio puede existir sin ser escribible: se comprueba también la
# escritura del marcador, no solo su creación.
if ! mkdir -p "$target_dir" 2>/dev/null ||
  ! printf '%s\n' "$workspace_root" >"$target_dir/.workspace-path" 2>/dev/null; then
  printf 'cargo-target-cache: aviso: no se pudo preparar %s; se usa target/ del proyecto\n' \
    "$target_dir" >&2
  exec "$real_cargo" "$@"
fi

if [ "${CARGO_TARGET_CACHE_PRINT_TARGET_DIR:-0}" = "1" ]; then
  printf '%s\n' "$target_dir"
  exit 0
fi

# Regla 4: se cede el proceso a cargo real con el mismo argv.
export CARGO_TARGET_DIR="$target_dir"
exec "$real_cargo" "$@"
