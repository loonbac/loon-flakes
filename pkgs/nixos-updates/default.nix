# Comando custom `nixos-updates`: comprueba y muestra las actualizaciones de
# paquetes disponibles entre la configuración actual de NixOS y remote nixpkgs,
# y si lo anunciado se puede aplicar ya sin compilar nada de nixpkgs.
{ pkgs, lib }:

let
  # Analizador compartido por `gate` y `check`: lee un dry-run y decide qué de
  # lo que habría que construir bloquea la actualización.
  #   python3 <gateScript> analyze <workdir> <dry-run.txt> <cache-dir>
  # Salida: 0 = aplicable, 3 = faltan binarios publicados, 2 = análisis fallido.
  gateScript = pkgs.writeText "nixos-updates-gate.py" ''
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time

CACHE = "https://cache.nixos.org"
BATCH = 60
WORKERS = 8
RETRIES = 2
SHOWN = 10

# Lo que NixOS fabrica para ESTA máquina: /etc, unidades, sudoers, reglas,
# initrd, activación y las completions de fish por paquete. Depende de esta
# configuración, así que no existe en ninguna cache y se genera en segundos.
PLUMBING = [
    r"^cargo-package-", r"^crate-", r"-vendor-dir", r"_fish-completions",
    r"^Cargo\.", r"^X-",
    r"^(etc|sudoers|unit-|system-path|user-units|activation|switch-to-configuration)",
    r"^(zram-generator\.conf|zswap|nvidia-|nixos-system|passwd|group|nixos-)",
    r"-rules\.drv$", r"(\.conf|\.settings|-conf|-settings)\.drv$", r"-nixos\.rules$",
    r"^(activate|boot\.json|man-paths|hwdb|firmware|dbus-1|ensure-all-wrappers|shutdown-ramfs|issue|initrd-|nixos-version|nixos-help|X-Restart-Triggers-)",
    r"^(system-(units|generators|shutdown|path)|user-(units|generators))",
]

# Propios, unfree (Hydra no los construye) y flakes externos sin cache pública.
# Se comparan contra el nombre de la DERIVACIÓN, no del paquete: zen-browser
# llega como "zen.linux-x86_64.tar.xz" y "zen-browser-unwrapped-*". Ojo:
# linux-*-modules y rustc-* no van aquí; deben seguir bloqueando (Hydra los
# publica con retraso). mpvpaper SÍ va: pkgs/mpvpaper-fixed le cambia src y
# version, así que ese hash nunca existirá en cache.nixos.org.
THIRD_PARTY = [
    r"antigravity", r"^loon-", r"^loon$", r"citron", r"millennium", r"^accela",
    r"sls-steam", r"veadotube-mini", r"^obs-", r"^wrapped-obs-", r"^steamidra",
    r"newtab-dashboard", r"^gentle-", r"^engram", r"^pi-", r"^pi$", r"cline",
    r"better-claude", r"^zen[.-]", r"^helium", r"code-insiders", r"vscode",
    r"equibop", r"pear-desktop", r"cargo-target-cache", r"anydesk",
    r"google-chrome", r"^port-", r"lanzaboote", r"lzbt", r"^steam",
    r"win11osx-cursor", r"mpv-with-scripts", r"heroic", r"claude-code",
    r"^mpvpaper",
]

TRANSIENT = re.compile(
    r"\b(429|500|502|503|504)\b|timed? ?out|could not resolve|couldn't resolve"
    r"|connection (refused|reset)|unable to download", re.I)
NOT_PUBLISHED = re.compile(r"is not valid|don't know how to build", re.I)


def name_of(path):
    """Nombre sin el hash del store: 'hash-port-0.1.10.drv' -> 'port-0.1.10.drv'."""
    return re.sub(r"^[0-9a-z]{32}-", "", path.rsplit("/", 1)[-1])


def label(path):
    name = name_of(path)
    return name[:-4] if name.endswith(".drv") else name


def parse_dry_run(text):
    built, fetched, cur = [], [], None
    for line in text.splitlines():
        stripped = line.strip()
        # Nix usa la forma singular ("this derivation will be built") con un solo
        # elemento; ignorarla dejaría pasar una actualización sin medir.
        if line.startswith(("these ", "this ")) and ("will be built" in line or "will be fetched" in line):
            cur = "built" if "will be built" in line else "fetched"
            continue
        if cur and stripped.startswith("/nix/store/"):
            (built if cur == "built" else fetched).append(stripped)
        elif cur and stripped and not line.startswith("  "):
            cur = None
    return built, fetched


def own_packages(work):
    """Paquetes exportados por el flake y carpetas de pkgs/: solo los construye esta máquina."""
    names = set()
    try:
        probe = subprocess.run(
            ["nix", "eval", "--json", "--apply", "builtins.attrNames",
             work + "#packages.x86_64-linux"],
            capture_output=True, text=True, timeout=300)
        if probe.returncode == 0:
            names.update(json.loads(probe.stdout))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    pkgs_dir = os.path.join(work, "pkgs")
    if os.path.isdir(pkgs_dir):
        names.update(entry for entry in os.listdir(pkgs_dir)
                     if os.path.isdir(os.path.join(pkgs_dir, entry)))
    return names


def allow_patterns():
    allow_file = os.path.expanduser("~/.config/nixos-updates-gate-allow")
    if not os.path.exists(allow_file):
        return []
    with open(allow_file) as handle:
        return [l.strip() for l in handle
                if l.strip() and not l.strip().startswith("#")]


def is_local(path, patterns, own):
    name = name_of(path)
    if any(re.search(pattern, name) for pattern in patterns):
        return True
    base = label(path)
    return any(base == package or base.startswith(package + "-") for package in own)


def show_derivations(derivations):
    """Una llamada a `nix derivation show` por lote, en vez de una por derivación."""
    nodes = {}
    for start in range(0, len(derivations), BATCH):
        batch = derivations[start:start + BATCH]
        result = subprocess.run(["nix", "derivation", "show", *batch],
                                capture_output=True, text=True, timeout=600)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip()[-500:])
        data = json.loads(result.stdout)
        nodes.update(data.get("derivations", data))
    found = {}
    for derivation in derivations:
        node = nodes.get(derivation) or nodes.get(derivation.rsplit("/", 1)[-1])
        if node is None:
            raise RuntimeError("sin datos de " + derivation)
        found[derivation] = node
    return found


def is_download(node):
    outputs = node.get("outputs") or {}
    return node.get("builder") == "builtin:fetchurl" or any(
        output.get("hash") for output in outputs.values())


def output_paths(node):
    paths = []
    for output in (node.get("outputs") or {}).values():
        path = output.get("path", "")
        if path:
            paths.append(path if path.startswith("/nix/store/") else "/nix/store/" + path)
    return paths


def probe(path):
    """True publicada, False no publicada, None sin respuesta clara del cache."""
    for attempt in range(RETRIES + 1):
        try:
            result = subprocess.run(["nix", "path-info", "--store", CACHE, path],
                                    capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            result = None
        if result is not None:
            if result.returncode == 0:
                return True
            if NOT_PUBLISHED.search(result.stderr) and not TRANSIENT.search(result.stderr):
                return False
        if attempt < RETRIES:
            time.sleep(2 * (attempt + 1))
    return None


def verdict(node):
    """Necesita todas las salidas publicadas.

    La derivación aparece en el dry-run justamente porque le falta al menos una
    de las salidas que el sistema necesita; con una sola publicada el gate
    prometería una descarga que no existe y la actualización compilaría.
    """
    answers = []
    for path in output_paths(node):
        answer = probe(path)
        if answer is False:
            return False
        answers.append(answer)
    return True if answers and all(a is True for a in answers) else None


def analyze(work, dry_path, cache_dir):
    with open(dry_path, errors="replace") as handle:
        built, fetched = parse_dry_run(handle.read())

    nodes = show_derivations(built)
    patterns = allow_patterns() + PLUMBING + THIRD_PARTY
    own = own_packages(work)

    downloads, local, candidates = [], [], []
    for derivation in built:
        node = nodes[derivation]
        if is_download(node):
            downloads.append(derivation)
        elif is_local(derivation, patterns, own):
            local.append(derivation)
        else:
            candidates.append(derivation)

    cached, missing, unverified = [], [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        pending = {pool.submit(verdict, nodes[d]): d for d in candidates}
        for future in concurrent.futures.as_completed(pending):
            derivation = pending[future]
            try:
                answer = future.result()
            except Exception:
                answer = None
            if answer:
                cached.append(derivation)
            else:
                missing.append(derivation)
                if answer is None:
                    unverified.append(derivation)

    blockers = sorted(label(d) for d in missing)
    state = "BLOCKED" if missing else "READY"
    report = [
        "gate: " + state,
        "  descargas (FOD)                  : " + str(len(downloads)),
        "  descargables del cache           : " + str(len(cached) + len(fetched)),
        "  generados aqui (config/propios)  : " + str(len(local)),
        "  compilaciones reales             : " + str(len(missing)),
    ]
    if unverified:
        report.append("    sin respuesta del cache        : " + str(len(unverified)))
    if blockers:
        report.append("  falta binario publicado para:")
        report.extend("    " + name for name in blockers[:SHOWN])
        if len(blockers) > SHOWN:
            report.append("    ... y " + str(len(blockers) - SHOWN) + " mas")
    report_text = "\n".join(report) + "\n"

    gate = {
        "state": state,
        "counts": {
            "downloads": len(downloads),
            "cached": len(cached) + len(fetched),
            "local": len(local),
            "missing": len(missing),
        },
        "unverified": len(unverified),
        "blockers": blockers,
        "checked": int(time.time()),
    }
    for name, content in (("gate.txt", report_text),
                          ("gate.json", json.dumps(gate, indent=2) + "\n")):
        target = os.path.join(cache_dir, name)
        temporary = os.path.join(cache_dir, ".%s.%d.tmp" % (name, os.getpid()))
        with open(temporary, "w") as handle:
            handle.write(content)
        os.replace(temporary, target)

    print(report_text)
    return 3 if missing else 0


def main():
    if len(sys.argv) != 5 or sys.argv[1] != "analyze":
        print("Uso: nixos-updates-gate.py analyze <workdir> <dry-run.txt> <cache-dir>",
              file=sys.stderr)
        sys.exit(2)
    try:
        code = analyze(*sys.argv[2:5])
    except Exception as error:
        print("gate: no se pudo analizar el dry-run: %s" % error, file=sys.stderr)
        sys.exit(2)
    sys.exit(code)


if __name__ == "__main__":
    main()
'';

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

STATUS_PREFIX = "Estado: "

def load_gate(cache_dir):
    try:
        return json.loads((cache_dir / "gate.json").read_text())
    except (OSError, ValueError):
        return {}

def format_blockers(gate, limit=5):
    blockers = [str(name) for name in gate.get("blockers") or []]
    if not blockers:
        return "(sin detalle)"
    text = ", ".join(blockers[:limit])
    if len(blockers) > limit:
        text += " y %d mas" % (len(blockers) - limit)
    return text

def strip_status(summary):
    lines = summary.splitlines()
    for index, line in enumerate(lines):
        if line.startswith(STATUS_PREFIX):
            lines = lines[:index]
            break
    return "\n".join(lines).rstrip("\n") + "\n"

def record_applicability(cache_dir, code):
    """Traduce el veredicto del analizador a `applicable` y al bloque de estado.

    Solo se escribe con una respuesta clara: si el cache no contestó (sin red)
    o el análisis falló, `applicable` desaparece y todo sigue como antes.
    """
    applicable_file = cache_dir / "applicable"
    summary_file = cache_dir / "summary.txt"
    summary = strip_status(read_text(summary_file))
    gate = load_gate(cache_dir) if code in ("0", "3") else {}
    counts = gate.get("counts") or {}
    missing = int(counts.get("missing", 0) or 0)
    unverified = int(gate.get("unverified", 0) or 0)

    applicable = None
    if gate and code == "0" and missing == 0:
        applicable = True
    elif gate and code == "3" and missing > unverified:
        applicable = False

    if applicable is None:
        try:
            applicable_file.unlink()
        except FileNotFoundError:
            pass
        atomic_write(summary_file, summary)
        print("Aplicabilidad sin medir (codigo %s)." % code)
        return

    # El aviso "Ejecuta 'rebuild update'" del resumen se quita cuando ya hay
    # veredicto: lo reemplaza la línea de estado. Si la medición falla, el
    # resumen se queda tal cual y conserva la pista.
    body = "\n".join(
        line for line in summary.splitlines()
        if line.strip() != "Ejecuta 'rebuild update' para aplicar."
    )
    if applicable:
        status = STATUS_PREFIX + "aplicable, ejecuta 'rebuild update'."
    else:
        status = STATUS_PREFIX + "NO aplicable todavia. NixOS aun no publica: %s." % format_blockers(gate)
    atomic_write(applicable_file, ("1" if applicable else "0") + "\n")
    atomic_write(summary_file, body + "\n" + status + "\n")
    print(status)

def pending_count(cache_dir):
    """Versiones que se pueden anunciar.

    Si el gate ya midió y no deja aplicar ninguna, no hay nada pendiente: la
    barra y el banner se comportan como "al día" y el detalle de qué falta
    queda en el tooltip y en el resumen.
    """
    count = read_int(cache_dir / "count")
    return 0 if read_text(cache_dir / "applicable") == "0" else count

def waybar_status(cache_dir):
    state = read_text(cache_dir / "state", "unknown")
    count = read_int(cache_dir / "count")
    pending = pending_count(cache_dir)
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
        # Hay versiones nuevas pero el gate todavía no las dejaría aplicar: la
        # barra se queda como "al día" y el detalle viaja en el tooltip, porque
        # anunciar un pendiente que 'rebuild update' rechazaría es una promesa
        # falsa.
        blocked = count > 0 and pending == 0
        if stale:
            alt = "stale"
        else:
            alt = "has-updates" if pending > 0 else "updated"
        text = str(pending) if pending > 0 else ""
        if blocked:
            lines.append("Sin actualizaciones aplicables.")
            lines.append("\n%d anunciadas, ninguna publicada todavia. NixOS aun no publica: %s"
                         % (count, format_blockers(load_gate(cache_dir))))
        elif summary:
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

    elif mode == "applicability":
        record_applicability(cache_dir, sys.argv[2] if len(sys.argv) > 2 else "")

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
        count = pending_count(cache_dir)
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
    DRY_TMP="$CACHE_DIR/.dry-run.$$.tmp"
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
      ${pkgs.coreutils}/bin/rm -f "$BASE_TMP" "$CANDIDATE_TMP" "$DRY_TMP"
      # Solo `check` puede dejar constancia de un fallo. Un lector (waybar,
      # banner, count, show) que muere por SIGPIPE al cerrarse el pipe no debe
      # pintar la barra como si la comprobación hubiera fallado.
      case "$CMD" in
        check|--check|-c) ;;
        *) return 0 ;;
      esac
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

    # ¿Lo anunciado se puede aplicar ya? Mismo analizador que `gate`, sobre la
    # copia que ya tiene los inputs actualizados. Si el dry-run o el sondeo
    # fallan (sin red, evaluación rota) la comprobación no se vuelve error:
    # `applicable` queda sin escribir y la barra solo cuenta versiones.
    measure_applicability() {
      local code=0
      ${pkgs.coreutils}/bin/rm -f "$CACHE_DIR/applicable"
      local count
      count="$(< "$CACHE_DIR/count")" || return 0
      case "$count" in
        ""|0|*[!0-9]*) return 0 ;;
      esac
      echo -e "\033[34m󰂓\033[0m Midiendo si la actualización es aplicable..."
      CURRENT_STEP="medición de aplicabilidad"
      if ! /run/current-system/sw/bin/nixos-rebuild dry-run --flake "$FLAKE_CACHE#$HOST" \
        > "$DRY_TMP" 2>&1; then
        echo "El dry-run falló; la aplicabilidad queda sin medir." >> "$RUN_LOG"
        ${pkgs.coreutils}/bin/tail -n 20 "$DRY_TMP" >> "$RUN_LOG" || true
        ${pkgs.coreutils}/bin/rm -f "$DRY_TMP"
        return 0
      fi
      ${pkgs.python3}/bin/python3 ${gateScript} analyze \
        "$FLAKE_CACHE" "$DRY_TMP" "$CACHE_DIR" >> "$RUN_LOG" 2>&1 || code=$?
      ${pkgs.coreutils}/bin/rm -f "$DRY_TMP"
      ${pkgs.python3}/bin/python3 ${pythonScript} applicability "$code" \
        >> "$RUN_LOG" 2>&1 || true
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
          # Se vuelve a medir mientras el veredicto guardado no sea "aplicable":
          # con el mismo fingerprint un 0 antiguo no se revisaría nunca y la
          # actualización seguiría saliendo como no aplicable aun después de que
          # NixOS publique los binarios.
          applicable_state=""
          if [ -f "$CACHE_DIR/applicable" ]; then
            applicable_state="$(< "$CACHE_DIR/applicable")"
          fi
          if [ "$applicable_state" != "1" ]; then
            measure_applicability
          fi
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
        measure_applicability
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

        gate_code=0
        ${pkgs.python3}/bin/python3 ${gateScript} analyze \
          "$WORK" "$WORK/dry.txt" "$CACHE_DIR" || gate_code=$?
        if [ "$gate_code" -eq 3 ]; then
          echo "Actualizacion NO aplicada. Forzala con 'rebuild update force'."
        fi
        exit "$gate_code"
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
