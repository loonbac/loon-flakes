# Script "niri-cycle": moverse entre ventanas (columnas) con wrap infinito.
# En niri las ventanas viven en columnas horizontales dentro de un workspace:
#   - focus-column-left/right mueve el foco entre columnas.
# Si estás en la primera columna y das a la izquierda, salta a la última
# columna de la derecha (y viceversa). Los workspaces se cambian con
# Super+1..9 (focus-workspace), NO con este script.
#
# Uso:
#   niri-cycle left   # columna anterior, con wrap
#   niri-cycle right  # columna siguiente, con wrap
{ pkgs, lib }:

pkgs.writeShellScriptBin "niri-cycle" ''
  set -euo pipefail

  DIR=''${1:-right}
  JQ="${pkgs.jq}/bin/jq"

  get_focused() {
    niri msg -j windows | "$JQ" -r '.[] | select(.is_focused == true) | .id' | head -1
  }

  before="$(get_focused)"
  if [ -z "$before" ]; then
    exit 0
  fi

  # Movimiento normal: columna anterior/siguiente.
  if [ "$DIR" = "left" ]; then
    niri msg action focus-column-left
  else
    niri msg action focus-column-right
  fi

  after="$(get_focused)"
  if [ "$after" != "$before" ]; then
    exit 0
  fi

  # No cambió el foco: estábamos en el extremo → wrap al otro lado.
  # Avanzamos en la dirección contraria hasta que el foco deje de moverse
  # (el bucle está acotado; niri msg es un socket local, es instantáneo).
  prev="$before"
  for _ in $(seq 1 100); do
    if [ "$DIR" = "left" ]; then
      niri msg action focus-column-right
    else
      niri msg action focus-column-left
    fi
    cur="$(get_focused)"
    if [ "$cur" = "$prev" ]; then
      break
    fi
    prev="$cur"
  done
''
