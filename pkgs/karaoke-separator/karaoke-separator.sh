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
  polarformer) model=model_bs_polarformer_float16 ;;
  *) usage >&2; exit 2 ;;
esac

input=$2
output=${3:-"$(dirname "$input")/separado-$1"}
mkdir -p "$output"

if [ "$1" = "polarformer" ]; then
  cd "$runtime_dir"
  exec "$venv_dir/bin/python" -c '
from inference import Separator
import os
import sys
import sysconfig

# El Python del venv apunta al intérprete Nix, cuyo include no existe bajo
# /run/current-system/sw. Triton lo necesita para compilar su helper CUDA.
get_paths = sysconfig.get_paths
def nix_get_paths(*args, **kwargs):
    paths = get_paths(*args, **kwargs)
    paths["include"] = os.environ["KARAOKE_PYTHON_INCLUDE_DIR"]
    return paths
sysconfig.get_paths = nix_get_paths

Separator(source="hface").custom_separate(
    input_files=[sys.argv[1]], output_dir=sys.argv[2], output_format="flac",
    template="NAME_(STEM)_MODEL", model_type="bs_roformer",
    ckpt=sys.argv[3], conf=sys.argv[4],
)
' "$input" "$output" "$models_dir/model_bs_polarformer_float16.ckpt" "$models_dir/model_bs_polarformer_float16.yaml"
fi

exec "$venv_dir/bin/python" "$runtime_dir/inference.py" separate \
  -i "$input" -o "$output" -of flac -mn "$model" -tm 'NAME_(STEM)_MODEL'
