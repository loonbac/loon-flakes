#!/usr/bin/env bash
# Pruebas enfocadas de los motivos de pausa de mpvpaper-wallpaper.
#
# Reciben la ruta del script compilado. No necesitan mpvpaper, niri ni una
# sesión gráfica: sin socket IPC los envíos son no-ops y toda la lógica de
# motivos (procedencia, antigüedad, reconciliación) corre igual. Eso es
# deliberado: es la parte que puede regresionar en silencio.
set -uo pipefail

script=$1
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

export HOME="$sandbox/home"
export XDG_RUNTIME_DIR="$sandbox/run"
mkdir -p "$HOME/Videos/Wallpapers" "$XDG_RUNTIME_DIR"
pause_dir="$XDG_RUNTIME_DIR/mpvpaper-wallpaper/paused.d"

failures=0

check() { # nombre, esperado, actual
  if [ "$2" = "$3" ]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FALLA %s\n  esperado: %s\n  actual  : %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

check_contains() { # nombre, aguja, pajar
  case "$3" in
    *"$2"*) printf 'ok    %s\n' "$1" ;;
    *)
      printf 'FALLA %s\n  falta: %s\n  en    : %s\n' "$1" "$2" "$3"
      failures=$((failures + 1))
      ;;
  esac
}

# ---------------------------------------------------------------------------
# S1: el motivo guarda su hora de creación y su origen.
# ---------------------------------------------------------------------------
"$script" pause manual >/dev/null 2>&1
check "S1 el marcador registra epoch y origin" "epoch origin" \
  "$(sed -e 's/=.*//' "$pause_dir/manual" | tr '\n' ' ' | sed 's/ $//')"
check "S1 sin OWNER el origen es cli" "cli" \
  "$(sed -n 's/^origin=//p' "$pause_dir/manual")"

# ---------------------------------------------------------------------------
# S2: 'reasons' informa motivo, antigüedad y origen (tres campos, tabulados).
# ---------------------------------------------------------------------------
printf 'epoch=%s\norigin=cli\n' "$(( $(date +%s) - 3720 ))" > "$pause_dir/manual"
check "S2 linea con motivo/edad/origen" "$(printf 'manual\t1h2m\tcli')" "$("$script" reasons)"

# Un motivo sin metadatos (escrito por una versión anterior) no rompe la salida.
printf '' > "$pause_dir/viejo"
check "S2 motivo legado sin metadatos" "$(printf 'viejo\t?\tdesconocido')" \
  "$("$script" reasons | grep '^viejo')"
rm -f "$pause_dir/viejo"

# ---------------------------------------------------------------------------
# S3/S4: un motivo cuyo dueño ya no existe se retira al reconciliar.
# ---------------------------------------------------------------------------
"$script" pause opaque-window pid:999999 >/dev/null 2>&1
check "S3 el origen conserva el pid del dueño" "pid:999999" \
  "$(sed -n 's/^origin=//p' "$pause_dir/opaque-window")"

check_contains "S4 reconcile avisa el motivo huérfano" "opaque-window" \
  "$("$script" reconcile 2>&1)"
check "S4 los huérfanos desaparecen" "" \
  "$(ls "$pause_dir" 2>/dev/null | grep -x 'opaque-window' || true)"

# Un dueño vivo conserva su motivo: el watcher no se retira a sí mismo.
"$script" pause opaque-window "pid:$$" >/dev/null 2>&1
"$script" reconcile >/dev/null 2>&1
check "S4 un dueño vivo conserva su motivo" "opaque-window" \
  "$(ls "$pause_dir" 2>/dev/null | grep -x 'opaque-window' || true)"

# Un motivo 'cli' nunca se retira solo, aunque sea viejo.
printf 'epoch=%s\norigin=cli\n' "$(( $(date +%s) - 999999 ))" > "$pause_dir/manual"
"$script" reconcile >/dev/null 2>&1
check_contains "S4 cli sobrevive a reconcile" "manual" "$("$script" reasons)"

# ---------------------------------------------------------------------------
# S5: consultar nunca muta el estado.
# ---------------------------------------------------------------------------
"$script" pause opaque-window pid:999997 >/dev/null 2>&1
"$script" reasons >/dev/null 2>&1
check "S5 reasons no retira huérfanos" "opaque-window" \
  "$(ls "$pause_dir" 2>/dev/null | grep -x 'opaque-window' || true)"
check "S5 status sin socket sigue siendo stopped" "stopped" "$("$script" status 2>/dev/null)"
check "S5 status no retira huérfanos" "opaque-window" \
  "$(ls "$pause_dir" 2>/dev/null | grep -x 'opaque-window' || true)"

# ---------------------------------------------------------------------------
# S6: por el socket IPC, 'reconcile' solo reanuda cuando retiró el último
# motivo. Sin eso, un 'status' deshacía en silencio una pausa puesta a mano en
# el socket de mpv, que es estado válido del usuario.
# ---------------------------------------------------------------------------
cat > "$sandbox/fake-mpv-ipc.py" <<'PY'
#!/usr/bin/env python3
"""Servidor IPC mínimo de mpv para las pruebas del wallpaper.

Registra cada comando que el script le envía, para poder afirmar qué manda y qué
no manda: es la única forma de comprobar que 'status' no fija la pausa y que
'reconcile' no reanuda una pausa que no puso él.
"""

from __future__ import annotations

import os
import socket
import sys

path, log = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)
try:
    while True:
        conn, _ = server.accept()
        conn.settimeout(2.0)
        data = b""
        try:
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
        except OSError:
            pass
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(data.decode("utf-8", "replace").strip() + "\n")
        try:
            conn.sendall(b'{"data":false}\n')
        except OSError:
            pass
        conn.close()
finally:
    server.close()
PY

ipc_server="$sandbox/fake-mpv-ipc.py"
ipc_log="$sandbox/ipc.log"
ipc_socket="$XDG_RUNTIME_DIR/mpvpaper-wallpaper/mpv.sock"

run_with_ipc() { # comando...
  : > "$ipc_log"
  # El servidor anterior deja su socket en disco: si no se borra, el sondeo de
  # abajo da por listo un socket muerto y el comando habla con nadie.
  rm -f "$ipc_socket"
  timeout 10 python3 "$ipc_server" "$ipc_socket" "$ipc_log" >/dev/null 2>"$sandbox/ipc.err" &
  local server_pid=$!
  local attempt
  for attempt in $(seq 1 50); do
    [ -S "$ipc_socket" ] && break
    sleep 0.1
  done
  if [ ! -S "$ipc_socket" ]; then
    printf 'FALLA el servidor IPC falso no llegó a escuchar: %s\n' "$(cat "$sandbox/ipc.err" 2>/dev/null)" >&2
    failures=$((failures + 1))
  fi
  "$@" >/dev/null 2>&1
  sleep 0.5
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}

rm -f "$pause_dir"/*
run_with_ipc "$script" reconcile
check "S6 sin motivos reconcile no manda IPC" "" "$(cat "$ipc_log")"

"$script" pause opaque-window "pid:$$" >/dev/null 2>&1
run_with_ipc "$script" status
check "S6 status nunca fija la pausa" "" "$(grep 'set_property' "$ipc_log" || true)"

rm -f "$pause_dir"/*
"$script" pause opaque-window pid:999998 >/dev/null 2>&1
run_with_ipc "$script" reconcile
check_contains "S6 reconcile con poda sí reanuda" '"pause",false' "$(cat "$ipc_log")"

# ---------------------------------------------------------------------------
# Regresión: la semántica de resume no cambia.
# ---------------------------------------------------------------------------
rm -f "$pause_dir"/*
"$script" pause manual >/dev/null 2>&1
"$script" pause power-profile >/dev/null 2>&1
"$script" resume power-profile >/dev/null 2>&1
check "resume MOTIVO retira solo el suyo" "manual" "$("$script" reasons | cut -f1)"
"$script" resume >/dev/null 2>&1
check "resume sin motivo retira todos" "" "$("$script" reasons)"

"$script" pause 'mal motivo' >/dev/null 2>&1
check "motivo inválido falla con exit 1" "1" "$?"

if [ "$failures" -ne 0 ]; then
  printf '\n%d comprobación(es) fallaron\n' "$failures" >&2
  exit 1
fi
printf '\ntodos los motivos de pausa se comportan como se espera\n'
