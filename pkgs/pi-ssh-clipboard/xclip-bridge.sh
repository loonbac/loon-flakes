#!/usr/bin/env bash
set -u

real_xclip="@real_xclip@"
curl_bin="@curl@"

selection=""
target=""
output=false
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -selection|-sel)
      if ((i + 1 < ${#args[@]})); then
        selection="${args[$((i + 1))]}"
        ((i += 1))
      fi
      ;;
    -target|-t)
      if ((i + 1 < ${#args[@]})); then
        target="${args[$((i + 1))]}"
        ((i += 1))
      fi
      ;;
    -out|-o)
      output=true
      ;;
  esac
done

runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
bridge_socket="${PI_SSH_CLIPBOARD_SOCKET:-$runtime_dir/pi-ssh-clipboard.sock}"
is_ssh=false
if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
  is_ssh=true
fi

bridge_get() {
  "$curl_bin" \
    --silent \
    --show-error \
    --fail \
    --max-time 4 \
    --max-filesize 52428800 \
    --unix-socket "$bridge_socket" \
    "http://localhost$1"
}

if $is_ssh && $output && [[ "$selection" == "clipboard" && -S "$bridge_socket" ]]; then
  case "$target" in
    TARGETS)
      if bridge_get /v1/types; then
        exit 0
      fi
      ;;
    image/png|image/jpeg|image/webp|image/gif)
      if bridge_get "/v1/image/$target"; then
        exit 0
      fi
      ;;
  esac
fi

exec "$real_xclip" "$@"
