#!/usr/bin/env bash
set -euo pipefail

project_dir="$HOME/Proyectos/separador-vocal"
runtime_dir="$project_dir/mvsepless"
venv_dir="$project_dir/.venv"
models_dir="$project_dir/modelos"

usage() {
  cat <<'EOF'
Uso:
  karaoke-separator instalar
  karaoke-separator <gabox-invertido|frazer-becruily|anvuew|polarformer> <cancion> [directorio-salida]

Los pesos se mantienen en ~/Proyectos/separador-vocal/modelos. Cada ejecución
carga el modelo en la GPU sólo mientras separa la canción y lo libera al salir.
EOF
}

install_runtime() {
  mkdir -p "$project_dir" "$models_dir"
  if [ ! -d "$runtime_dir/.git" ]; then
    git clone --depth 1 --branch dzeta https://github.com/noblebarkrr/mvsepless.git "$runtime_dir"
  fi
  ln -sfn ../modelos "$runtime_dir/separation_cache"
  if [ ! -x "$venv_dir/bin/python" ]; then
    uv venv --python python3 "$venv_dir"
  fi
  uv pip install --python "$venv_dir/bin/python" -r "$runtime_dir/requirements.txt"
}

if [ "${1:-}" = "instalar" ]; then
  install_runtime
  echo "Entorno listo. Los pesos se descargan con: karaoke-separator descargar"
  exit 0
fi

if [ "${1:-}" = "descargar" ]; then
  [ -x "$venv_dir/bin/python" ] || { echo "Primero ejecuta: karaoke-separator instalar" >&2; exit 1; }
  cd "$runtime_dir"
  exec "$venv_dir/bin/python" -c '
from inference import Separator
separator = Separator(source="hface")
for model in ("bs_karaoke_inv_gabox", "bs_karaoke_becruily", "bs_karaoke_anvuew", "bs_pope_vocals_zfturbo"):
    separator.download(model)
'
fi

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
[ -x "$venv_dir/bin/python" ] || { echo "Primero ejecuta: karaoke-separator instalar" >&2; exit 1; }

case "$1" in
  gabox-invertido) model=bs_karaoke_inv_gabox ;;
  frazer-becruily) model=bs_karaoke_becruily ;;
  anvuew) model=bs_karaoke_anvuew ;;
  polarformer) model=bs_pope_vocals_zfturbo ;;
  *) usage >&2; exit 2 ;;
esac

input=$2
output=${3:-"$(dirname "$input")/separado-$1"}
mkdir -p "$output"
exec "$venv_dir/bin/python" "$runtime_dir/inference.py" separate \
  -i "$input" -o "$output" -of flac -mn "$model" -tm 'NAME_(STEM)_MODEL'
