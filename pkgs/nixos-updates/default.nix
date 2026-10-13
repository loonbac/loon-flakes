# Comando custom `nixos-updates`: comprueba y muestra las actualizaciones de
# paquetes disponibles entre la configuración actual de NixOS y remote nixpkgs.
{ pkgs, lib }:

let
  manifestExpression = pkgs.writeText "nixos-updates-manifest.nix" ''
    packages:
    builtins.map
      (package:
        let
          parsed = builtins.parseDrvName package.name;
        in
        {
          name = package.pname or parsed.name;
          version = package.version or parsed.version;
        })
      packages
  '';

  pythonScript = pkgs.writeText "nixos-updates-formatter.py" ''
import html
import json
import os
import sys
import time
from pathlib import Path

COMMON_NAMES = {
    "firefox": "Firefox",
    "ghostty": "Ghostty",
    "neovim": "Neovim",
    "fish": "Fish",
    "openssh": "OpenSSH",
    "openssl": "OpenSSL",
    "zen-browser": "Zen Browser",
    "code-insiders": "Code Insiders",
    "obs-studio": "OBS Studio",
    "antigravity": "Antigravity",
    "antigravity-cli": "Antigravity CLI",
    "google-antigravity-cli": "Antigravity CLI",
    "vlc": "VLC",
    "cargo": "Cargo",
    "rustc": "Rustc",
    "go": "Go",
    "nodejs": "Node.js",
    "pnpm": "pnpm",
    "python3": "Python 3",
    "git": "Git",
    "gh": "GitHub CLI",
    "tailscale": "Tailscale",
    "waybar": "Waybar",
    "niri": "Niri",
    "yazi": "Yazi",
    "btop": "btop",
    "fastfetch": "Fastfetch",
    "equibop": "Equibop",
}

def clean_name(name):
    name_lower = name.lower()
    if name_lower in COMMON_NAMES:
        return COMMON_NAMES[name_lower]
    if name_lower.startswith("python3.13-"):
        name = name[11:]
    elif name_lower.startswith("python3-"):
        name = name[8:]
    return name.replace("-", " ").title()

def load_manifest(path):
    data = json.loads(path.read_text())
    packages = {}
    for item in data:
        name = str(item.get("name", "")).strip()
        version = str(item.get("version", "")).strip()
        if name and version:
            packages[name] = version
    return packages

def compare_manifests(base_path, candidate_path):
    base = load_manifest(base_path)
    candidate = load_manifest(candidate_path)
    updates = [
        (clean_name(name), base[name], candidate[name])
        for name in base.keys() & candidate.keys()
        if base[name] != candidate[name]
    ]
    added = [
        (clean_name(name), candidate[name])
        for name in candidate.keys() - base.keys()
    ]
    removed = [
        (clean_name(name), base[name])
        for name in base.keys() - candidate.keys()
    ]
    updates.sort(key=lambda item: item[0].lower())
    added.sort(key=lambda item: item[0].lower())
    removed.sort(key=lambda item: item[0].lower())
    return updates, added, removed

def format_count(count):
    if count == 1:
        return "1 actualización disponible"
    return "%d actualizaciones disponibles" % count

def atomic_write(path, content):
    tmp = path.with_name(".%s.%d.tmp" % (path.name, os.getpid()))
    tmp.write_text(content)
    tmp.replace(path)

def read_text(path, default=""):
    try:
        return path.read_text().strip()
    except (OSError, UnicodeError):
        return default

def read_int(path, default=0):
    try:
        return int(read_text(path))
    except ValueError:
        return default

def format_time(timestamp):
    if timestamp <= 0:
        return "nunca"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(timestamp))

def waybar_status(cache_dir):
    state = read_text(cache_dir / "state", "unknown")
    count = read_int(cache_dir / "count")
    summary = read_text(cache_dir / "summary.txt")
    error = read_text(cache_dir / "error.txt")
    last_check = read_int(cache_dir / "last-check")
    last_success = read_int(cache_dir / "last-success")

    lines = []
    if state == "checking":
        alt, text = "checking", "…"
        lines.append("Buscando actualizaciones…")
    elif state == "error":
        alt, text = "error", "!"
        lines.append(error or "La última comprobación falló.")
        lines.append("Revisa: nixos-updates logs")
    elif state == "ok":
        stale = last_success <= 0 or time.time() - last_success > 3 * 60 * 60
        alt = "stale" if stale else ("has-updates" if count > 0 else "updated")
        text = str(count) if count > 0 else ""
        if summary:
            lines.append(summary)
        else:
            lines.append("Sistema al día.")
    else:
        alt, text = "unknown", "?"
        lines.append("Aún no se ha completado ninguna comprobación.")

    if last_check > 0:
        lines.append("\nÚltimo intento: %s" % format_time(last_check))
    if state in ("checking", "error") and last_success > 0:
        lines.append("Último resultado válido: %s" % format_time(last_success))

    tooltip = html.escape("\n".join(lines))
    return {
        "text": text,
        "alt": alt,
        "tooltip": "<tt><span size=\"13000\">%s</span></tt>" % tooltip,
    }

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "parse"
    cache_dir = Path.home() / ".cache" / "nixos-updates"
    count_file = cache_dir / "count"
    summary_file = cache_dir / "summary.txt"

    if mode == "compare":
        if len(sys.argv) != 4:
            print("Expected base and candidate manifests.", file=sys.stderr)
            sys.exit(1)

        updates, added, removed = compare_manifests(
            Path(sys.argv[2]), Path(sys.argv[3])
        )
        
        count = len(updates)
        atomic_write(count_file, str(count) + "\n")

        lines = []
        lines.append("Actualizaciones disponibles")
        lines.append("────────────────────────────────────\n")

        if count > 0:
            for name, old_v, new_v in updates:
                lines.append("%-16s %-10s → %s" % (name, old_v, new_v))
            lines.append("\n" + format_count(count))
            lines.append("\nEjecuta 'rebuild update' para aplicar.")
        else:
            lines.append("No hay actualizaciones pendientes. Tu sistema está al día.")

        if added:
            lines.append("\nPaquetes nuevos en la configuración candidata:")
            for name, version in added:
                lines.append("+ %-16s %s" % (name, version))
        if removed:
            lines.append("\nPaquetes retirados de la configuración candidata:")
            for name, version in removed:
                lines.append("- %-16s %s" % (name, version))

        summary_content = "\n".join(lines) + "\n"
        atomic_write(summary_file, summary_content)
        print("Parsed %d updates." % count)

    elif mode == "waybar":
        print(json.dumps(waybar_status(cache_dir), ensure_ascii=False))

    elif mode == "banner":
        state = read_text(cache_dir / "state", "unknown")
        if state == "error":
            error = read_text(cache_dir / "error.txt", "La comprobación falló.")
            print("\033[31m⚠ NixOS Updates:\033[0m %s" % error)
            print("\033[90m  Ejecuta 'nixos-updates logs' para ver el detalle.\033[0m\n")
            sys.exit(0)
        if not count_file.exists():
            sys.exit(0)
        try:
            count = int(count_file.read_text().strip())
        except ValueError:
            sys.exit(0)

        if count <= 0:
            sys.exit(0)

        pkg_lines = []
        if summary_file.exists():
            for line in summary_file.read_text().splitlines():
                if " → " in line:
                    pkg_lines.append(line)

        print("\033[36m╭─ NixOS Updates\033[0m")
        if pkg_lines:
            if len(pkg_lines) <= 5:
                for pl in pkg_lines:
                    print("\033[36m│\033[0m  %s" % pl)
            else:
                for pl in pkg_lines[:4]:
                    print("\033[36m│\033[0m  %s" % pl)
                print("\033[36m│\033[0m  \033[90m... y %d más\033[0m" % (len(pkg_lines) - 4))
        print("\033[36m╰─\033[0m \033[90mEjecuta '\033[1;32mnixos-updates\033[0m\033[90m' para ver el resumen.\033[0m\n")

    elif mode == "show":
        state = read_text(cache_dir / "state", "unknown")
        if state == "checking":
            print("Buscando actualizaciones…")
        elif state == "error":
            print("Error: %s" % read_text(cache_dir / "error.txt", "La comprobación falló."))
            print("Ejecuta 'nixos-updates logs' para ver el detalle.")
            if summary_file.exists():
                print("\nÚltimo resultado válido:\n")
                print(summary_file.read_text(), end="")
        elif summary_file.exists():
            print(summary_file.read_text(), end="")
        else:
            print("No se han verificado actualizaciones aún.")
            print("Ejecuta 'nixos-updates check' para realizar la primera búsqueda.")

if __name__ == "__main__":
    main()
'';

  script = pkgs.writeShellScriptBin "nixos-updates" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.nix pkgs.coreutils pkgs.rsync pkgs.python3 ]}:$PATH"

    CACHE_DIR="$HOME/.cache/nixos-updates"
    FLAKE_DIR="$HOME/.nixos"
    FLAKE_CACHE="$CACHE_DIR/flake"
    BASE_MANIFEST="$CACHE_DIR/base-manifest.json"
    CANDIDATE_MANIFEST="$CACHE_DIR/candidate-manifest.json"
    BASE_TMP="$CACHE_DIR/.base-manifest.$$.tmp"
    CANDIDATE_TMP="$CACHE_DIR/.candidate-manifest.$$.tmp"
    RUN_LOG="$CACHE_DIR/.check.$$.log"
    MANIFEST_APPLY="$(< ${manifestExpression})"
    HOST="''${NIXOS_HOST:-$(< /proc/sys/kernel/hostname)}"

    mkdir -p "$CACHE_DIR"

    CMD="''${1:-show}"

    notify_waybar() {
      ${pkgs.systemd}/bin/systemctl --user kill \
        --kill-whom=main --signal=RTMIN+9 waybar.service >/dev/null 2>&1 || true
    }

    write_atomic() {
      local destination="$1"
      shift
      local temporary="$CACHE_DIR/.$(${pkgs.coreutils}/bin/basename "$destination").$$.tmp"
      ${pkgs.coreutils}/bin/printf '%s\n' "$*" > "$temporary"
      ${pkgs.coreutils}/bin/mv -f "$temporary" "$destination"
    }

    record_error() {
      local message="$1"
      write_atomic "$CACHE_DIR/error.txt" "$message"
      write_atomic "$CACHE_DIR/last-check" "$(${pkgs.coreutils}/bin/date +%s)"
      write_atomic "$CACHE_DIR/state" "error"
      if [ -f "$RUN_LOG" ]; then
        ${pkgs.coreutils}/bin/mv -f "$RUN_LOG" "$CACHE_DIR/latest.log"
      fi
      notify_waybar
    }

    FINALIZED=0
    CURRENT_STEP="inicialización"
    cleanup() {
      local code=$?
      ${pkgs.coreutils}/bin/rm -f "$BASE_TMP" "$CANDIDATE_TMP"
      if [ "$code" -ne 0 ] && [ "$FINALIZED" -eq 0 ]; then
        FINALIZED=1
        record_error "Comprobación interrumpida durante: $CURRENT_STEP"
      fi
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    finish_error() {
      local message="$1"
      local code="''${2:-1}"
      FINALIZED=1
      record_error "$message"
      echo "󰀦 $message" >&2
      if [ -f "$CACHE_DIR/latest.log" ]; then
        echo "Últimas líneas del diagnóstico:" >&2
        ${pkgs.coreutils}/bin/tail -n 30 "$CACHE_DIR/latest.log" >&2
      fi
      exit "$code"
    }

    run_logged() {
      local failure_message="$1"
      shift
      if "$@" >> "$RUN_LOG" 2>&1; then
        return 0
      else
        local code=$?
        finish_error "$failure_message" "$code"
      fi
    }

    evaluate_manifest() {
      local output="$1"
      local failure_message="$2"
      if ${pkgs.nix}/bin/nix eval --json \
        "$FLAKE_CACHE#nixosConfigurations.$HOST.config.environment.systemPackages" \
        --apply "$MANIFEST_APPLY" > "$output" 2>> "$RUN_LOG"; then
        return 0
      else
        local code=$?
        finish_error "$failure_message" "$code"
      fi
    }

    finish_success() {
      local fingerprint="$1"
      write_atomic "$CACHE_DIR/fingerprint" "$fingerprint"
      write_atomic "$CACHE_DIR/last-check" "$(${pkgs.coreutils}/bin/date +%s)"
      write_atomic "$CACHE_DIR/last-success" "$(${pkgs.coreutils}/bin/date +%s)"
      ${pkgs.coreutils}/bin/rm -f "$CACHE_DIR/error.txt"
      if [ -f "$RUN_LOG" ]; then
        ${pkgs.coreutils}/bin/mv -f "$RUN_LOG" "$CACHE_DIR/latest.log"
      fi
      write_atomic "$CACHE_DIR/state" "ok"
      FINALIZED=1
      notify_waybar
    }

    case "$CMD" in
      check|--check|-c)
        exec 9>"$CACHE_DIR/check.lock"
        if ! ${pkgs.util-linux}/bin/flock -n 9; then
          echo "Ya hay una comprobación de actualizaciones en curso."
          exit 0
        fi

        case "$HOST" in
          ""|*[!A-Za-z0-9_-]*)
            finish_error "Hostname no válido para seleccionar el flake: '$HOST'"
            ;;
        esac

        : > "$RUN_LOG"
        write_atomic "$CACHE_DIR/state" "checking"
        write_atomic "$CACHE_DIR/last-check" "$(${pkgs.coreutils}/bin/date +%s)"
        notify_waybar

        echo -e "\033[36m󰍉\033[0m Buscando actualizaciones de NixOS..."
        mkdir -p "$FLAKE_CACHE"

        # Sincronizar la config local a la caché excluyendo artefactos pesados
        CURRENT_STEP="sincronización de la configuración"
        run_logged "No se pudo sincronizar la configuración local." \
          ${pkgs.rsync}/bin/rsync -a --delete \
          --exclude='.git' \
          --exclude='target' \
          --exclude='result' \
          "$FLAKE_DIR/" "$FLAKE_CACHE/"

        if [ ! -d "$FLAKE_CACHE/.git" ]; then
          run_logged "No se pudo inicializar la caché Git." \
            ${pkgs.git}/bin/git -C "$FLAKE_CACHE" init -q
        fi
        run_logged "No se pudo preparar la configuración para Nix." \
          ${pkgs.git}/bin/git -C "$FLAKE_CACHE" add -A

        base_tree="$(${pkgs.git}/bin/git -C "$FLAKE_CACHE" write-tree 2>> "$RUN_LOG")" || \
          finish_error "No se pudo calcular la huella de la configuración base."
        base_fingerprint="$base_tree $HOST"

        CURRENT_STEP="evaluación del manifiesto base"
        if [ ! -f "$BASE_MANIFEST" ] \
          || [ ! -f "$CACHE_DIR/base-fingerprint" ] \
          || [ "$(< "$CACHE_DIR/base-fingerprint")" != "$base_fingerprint" ]; then
          echo -e "\033[35m󰒓\033[0m Evaluando paquetes fijados actualmente..."
          evaluate_manifest "$BASE_TMP" \
            "No se pudo evaluar el manifiesto de paquetes fijado."
          ${pkgs.coreutils}/bin/mv -f "$BASE_TMP" "$BASE_MANIFEST"
          write_atomic "$CACHE_DIR/base-fingerprint" "$base_fingerprint"
        else
          echo "Reutilizando el manifiesto base sin cambios." >> "$RUN_LOG"
        fi

        echo -e "\033[34m󱓞\033[0m Actualizando flake inputs..."
        CURRENT_STEP="actualización de los flake inputs"
        update_code=1
        for attempt in 1 2 3; do
          echo "Intento $attempt de 3 para actualizar los inputs." >> "$RUN_LOG"
          if ${pkgs.nix}/bin/nix flake update --flake "$FLAKE_CACHE" >> "$RUN_LOG" 2>&1; then
            update_code=0
            break
          else
            update_code=$?
          fi
          [ "$attempt" -eq 3 ] || ${pkgs.coreutils}/bin/sleep "$((attempt * 5))"
        done
        if [ "$update_code" -ne 0 ]; then
          finish_error "No se pudieron actualizar los flake inputs tras 3 intentos." "$update_code"
        fi

        # El árbol incluye la configuración local y el lock candidato actualizado.
        run_logged "No se pudo registrar el lock candidato." \
          ${pkgs.git}/bin/git -C "$FLAKE_CACHE" add -A
        candidate_tree="$(${pkgs.git}/bin/git -C "$FLAKE_CACHE" write-tree 2>> "$RUN_LOG")" || \
          finish_error "No se pudo calcular la huella de la configuración."
        candidate_fingerprint="$base_tree $candidate_tree $HOST"

        # Si ambos árboles son idénticos a los del último éxito, no es
        # necesario volver a evaluar sus listas de paquetes.
        if [ -f "$CACHE_DIR/fingerprint" ] \
          && [ -f "$CACHE_DIR/count" ] \
          && [ -f "$CACHE_DIR/summary.txt" ] \
          && [ "$(< "$CACHE_DIR/fingerprint")" = "$candidate_fingerprint" ]; then
          echo "Sin cambios desde la última comprobación." >> "$RUN_LOG"
          finish_success "$candidate_fingerprint"
          echo -e "\033[32m󰄬\033[0m Sin cambios desde la última comprobación."
          exit 0
        fi

        echo -e "\033[35m󰒓\033[0m Evaluando paquetes con los inputs nuevos..."
        CURRENT_STEP="evaluación del manifiesto candidato"
        evaluate_manifest "$CANDIDATE_TMP" \
          "No se pudo evaluar el manifiesto de paquetes candidato."
        ${pkgs.coreutils}/bin/mv -f "$CANDIDATE_TMP" "$CANDIDATE_MANIFEST"

        echo -e "\033[33m󰈙\033[0m Comparando versiones de programas..."
        CURRENT_STEP="comparación de versiones"
        run_logged "No se pudo generar el resumen de actualizaciones." \
          ${pkgs.python3}/bin/python3 ${pythonScript} compare \
          "$BASE_MANIFEST" "$CANDIDATE_MANIFEST"
        finish_success "$candidate_fingerprint"
        echo -e "\033[32m󰄬\033[0m Verificación completada.\n"
        if [ -f "$CACHE_DIR/summary.txt" ]; then
          cat "$CACHE_DIR/summary.txt"
        fi
        ;;

      gate|--gate|-g)
        # ¿Se puede aplicar una actualización de inputs sin compilar nada que no
        # sea propio? Trabaja sobre una copia desechable, así que el flake.lock
        # del repo no se toca. Salida: 0 = se puede, 3 = faltan binarios.
        exec 9>"$CACHE_DIR/gate.lock"
        if ! ${pkgs.util-linux}/bin/flock -n 9; then
          echo "Ya hay otra comprobación de actualizaciones en curso."
          exit 0
        fi

        case "$HOST" in
          ""|*[!A-Za-z0-9_-]*)
            echo "Hostname no válido para seleccionar el flake: '$HOST'" >&2
            exit 2
            ;;
        esac

        WORK="$(${pkgs.coreutils}/bin/mktemp -d)"
        trap '${pkgs.coreutils}/bin/rm -rf "$WORK"' EXIT
        ${pkgs.rsync}/bin/rsync -a --delete --exclude='.git' --exclude='target' \
          --exclude='result' "$FLAKE_DIR/" "$WORK/"
        ${pkgs.git}/bin/git -C "$WORK" init -q
        ${pkgs.git}/bin/git -C "$WORK" add -A

        echo "Actualizando inputs en la copia desechable..."
        if ! ${pkgs.nix}/bin/nix flake update --flake "$WORK" >"$WORK/update.log" 2>&1; then
          echo "No se pudieron actualizar los inputs; no se aplica nada." >&2
          ${pkgs.coreutils}/bin/tail -n 5 "$WORK/update.log" >&2
          exit 2
        fi

        echo "Midiendo qué habría que construir (dry-run)..."
        /run/current-system/sw/bin/nixos-rebuild dry-run --flake "$WORK#$HOST" \
          >"$WORK/dry.txt" 2>&1 || true

        ${pkgs.python3}/bin/python3 - "$WORK" "$WORK/dry.txt" "$CACHE_DIR" <<'PYEOF'
import concurrent.futures
import json
import os
import re
import subprocess
import sys

work, dry_path, cache_dir = sys.argv[1:4]
txt = open(dry_path, errors="replace").read()
built, fetched, cur = [], [], None
for line in txt.splitlines():
    stripped = line.strip()
    if line.startswith(("these ", "this ")) and ("will be built" in line or "will be fetched" in line):
        cur = "built" if "will be built" in line else "fetched"
        continue
    if cur and stripped.startswith("/nix/store/"):
        (built if cur == "built" else fetched).append(stripped)
    elif cur and stripped and not line.startswith("  "):
        cur = None


def name_of(path):
    """Nombre sin el hash del store: 'hash-port-0.1.10.drv' -> 'port-0.1.10.drv'."""
    return re.sub(r"^[0-9a-z]{32}-", "", path.rsplit("/", 1)[-1])


# Paquetes propios del flake: lo que solo esta maquina construye.
own = []
try:
    probe = subprocess.run(
        ["nix", "eval", "--raw", "--apply", "builtins.attrNames",
         work + "#packages.x86_64-linux"],
        capture_output=True, text=True, timeout=300)
    if probe.returncode == 0:
        own = probe.stdout.split()
except Exception:
    own = []

allow = []
allow_file = os.path.expanduser("~/.config/nixos-updates-gate-allow")
if os.path.exists(allow_file):
    allow = [l.strip() for l in open(allow_file)
             if l.strip() and not l.strip().startswith("#")]

# Dos grupos que se compilan aquí y no por un fallo de publicación:
#   1. lo tuyo: los crates que se vendorizan para compilar tu Rust, el
#      directorio de vendor y las variantes que NixOS genera por configuración
#      (completions de fish).
#   2. lo que NixOS fabrica para ESTA máquina: /etc, sudoers, unidades,
#      reglas de polkit, ficheros de configuración. No existen en ninguna cache
#      porque dependen de esta configuración; se construyen siempre.
third_party = [
    r"antigravity", r"^loon-", r"^loon$", r"citron", r"millennium", r"^accela",
    r"sls-steam", r"veadotube-mini", r"^obs-", r"^steamidra", r"newtab-dashboard",
    r"^gentle-", r"^engram", r"^pi-", r"^pi$", r"cline", r"better-claude",
    r"zen-browser", r"helium-browser", r"code-insiders", r"vscode",
    r"equibop", r"pear-desktop", r"cargo-target-cache",
]
local_patterns = [
    r"^cargo-package-", r"^crate-", r"-vendor-dir", r"_fish-completions",
    r"^Cargo\.", r"^X-",
    r"^(etc|sudoers|unit-|system-path|user-units|activation|switch-to-configuration)",
    r"^(zram-generator\.conf|zswap|nvidia-|nixos-system|passwd|group|nixos-)",
    r"-rules\.drv$", r"(\.conf|\.settings|-conf|-settings)\.drv$", r"-nixos\.rules$",
] + third_party


def is_local(name):
    for pattern in allow + local_patterns:
        if re.search(pattern, name):
            return True
    for package in own:
        if name == package or name.startswith(package + "-"):
            return True
    return False


def store_path(derivation):
    result = subprocess.run(["nix", "derivation", "show", derivation],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    data = json.loads(result.stdout)
    node = list(data.get("derivations", data).values())[0]
    outputs = node.get("outputs") or {}
    if not outputs:
        return None
    path = sorted(outputs.values(), key=lambda o: o.get("path", ""))[0].get("path", "")
    return path if path.startswith("/nix/store/") else "/nix/store/" + path


def published(path):
    return subprocess.run(
        ["nix", "path-info", "--store", "https://cache.nixos.org", path],
        capture_output=True).returncode == 0


local, foreign = [], []
for derivation in built:
    (local if is_local(name_of(derivation)) else foreign).append(derivation)

missing, available = [], []
with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
    pending = {pool.submit(published, store_path(d) or d): d for d in foreign}
    for future in concurrent.futures.as_completed(pending):
        target = pending[future]
        try:
            (available if future.result() else missing).append(target)
        except Exception:
            missing.append(target)

report = [
    "gate: " + ("READY" if not missing else "BLOCKED"),
    "  a descargar                      : " + str(len(fetched)),
    "  a construir                      : " + str(len(built)),
    "    lo tuyo, de tu config o de flakes sin cache : " + str(len(local)),
    "    con binario (se descarga)      : " + str(len(available)),
    "    sin binario publicado          : " + str(len(missing)),
]
if missing:
    report.append("  falta binario publicado para:")
    for derivation in sorted(missing)[:15]:
        report.append("    " + name_of(derivation))
    if len(missing) > 15:
        report.append("    ... y " + str(len(missing) - 15) + " mas")

report_text = "\n".join(report) + "\n"
with open(os.path.join(cache_dir, "gate.txt"), "w") as handle:
    handle.write(report_text)
print(report_text)
if missing:
    print("Actualizacion NO aplicada. Forzala con 'rebuild update force'.")
sys.exit(3 if missing else 0)
PYEOF
        ;;

      banner)
        ${pkgs.python3}/bin/python3 ${pythonScript} banner
        ;;

      waybar)
        ${pkgs.python3}/bin/python3 ${pythonScript} waybar
        ;;

      count)
        if [ -f "$CACHE_DIR/count" ]; then
          cat "$CACHE_DIR/count"
        else
          echo "0"
        fi
        ;;

      logs)
        if [ -f "$CACHE_DIR/latest.log" ]; then
          cat "$CACHE_DIR/latest.log"
        else
          echo "Todavía no hay un registro de comprobación."
        fi
        ;;

      show|list|status|*)
        ${pkgs.python3}/bin/python3 ${pythonScript} show
        ;;
    esac
  '';
in
script
