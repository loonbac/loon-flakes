# Comando custom `nix-updates`: comprueba y muestra las actualizaciones de
# paquetes disponibles entre la configuración actual de NixOS y remote nixpkgs.
{ pkgs, lib }:

let
  pythonScript = pkgs.writeText "nix-updates-formatter.py" ''
import sys
import re
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

def parse_nvd_diff(diff_text):
    updates = []
    added = []
    removed = []

    for line in diff_text.strip().splitlines():
        # Upgrades
        m_up = re.match(r'^\[U[+. ]*\]\s+#\d+\s+(\S+)\s+(.+)$', line)
        if m_up:
            pkg_name = m_up.group(1)
            ver_str = m_up.group(2).split(',')[0].strip()
            if '->' in ver_str:
                old_v, new_v = [v.strip() for v in ver_str.split('->', 1)]
                cname = clean_name(pkg_name)
                updates.append((cname, old_v, new_v))
            continue

        # Added
        m_add = re.match(r'^\[A[+. ]*\]\s+#\d+\s+(\S+)\s+(.+)$', line)
        if m_add:
            pkg_name = m_add.group(1)
            ver_str = m_add.group(2).split(',')[0].strip()
            added.append((clean_name(pkg_name), ver_str))
            continue

        # Removed
        m_rem = re.match(r'^\[R[+. ]*\]\s+#\d+\s+(\S+)\s+(.+)$', line)
        if m_rem:
            pkg_name = m_rem.group(1)
            ver_str = m_rem.group(2).split(',')[0].strip()
            removed.append((clean_name(pkg_name), ver_str))
            continue

    unique_updates = {}
    for cname, old_v, new_v in updates:
        if old_v != new_v:
            unique_updates[cname] = (old_v, new_v)

    res = [(k, v[0], v[1]) for k, v in unique_updates.items()]
    res.sort(key=lambda x: x[0].lower())
    return res, added, removed

def format_count(count):
    if count == 1:
        return "1 actualización disponible"
    return "%d actualizaciones disponibles" % count

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "parse"
    cache_dir = Path.home() / ".cache" / "nix-updates"
    diff_file = cache_dir / "diff.raw"
    count_file = cache_dir / "count"
    summary_file = cache_dir / "summary.txt"

    if mode == "parse":
        if not diff_file.exists():
            print("No diff file found.")
            sys.exit(1)
        
        diff_text = diff_file.read_text()
        updates, added, removed = parse_nvd_diff(diff_text)
        
        count = len(updates)
        count_file.write_text(str(count))

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

        summary_content = "\n".join(lines) + "\n"
        summary_file.write_text(summary_content)
        print("Parsed %d updates." % count)

    elif mode == "banner":
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
        print("\033[36m│\033[0m  \033[1;33m⚡ %s\033[0m" % format_count(count))
        print("\033[36m╰─\033[0m \033[90mEjecuta '\033[1;32mnix-updates\033[0m\033[90m' para ver el resumen o '\033[1;32mrebuild update\033[0m\033[90m' para aplicar.\033[0m\n")

if __name__ == "__main__":
    main()
'';

  script = pkgs.writeShellScriptBin "nix-updates" ''
    set -euo pipefail

    CACHE_DIR="$HOME/.cache/nix-updates"
    FLAKE_DIR="$HOME/.nixos"
    FLAKE_CACHE="$CACHE_DIR/flake"
    RESULT_LINK="$CACHE_DIR/result"

    mkdir -p "$CACHE_DIR"

    CMD="''${1:-show}"

    case "$CMD" in
      check|--check|-c)
        echo "🔍 Buscando actualizaciones de NixOS..."
        mkdir -p "$FLAKE_CACHE"
        
        # Sincronizar la config local a la caché excluyendo artefactos pesados
        ${pkgs.rsync}/bin/rsync -a --delete \
          --exclude='.git' \
          --exclude='target' \
          --exclude='result' \
          "$FLAKE_DIR/" "$FLAKE_CACHE/"

        if [ ! -d "$FLAKE_CACHE/.git" ]; then
          ${pkgs.git}/bin/git -C "$FLAKE_CACHE" init -q
        fi
        ${pkgs.git}/bin/git -C "$FLAKE_CACHE" add -A

        echo "📦 Actualizando flake inputs..."
        if ! ${pkgs.nix}/bin/nix flake update --flake "$FLAKE_CACHE"; then
          echo "⚠️ No se pudieron actualizar los inputs de Nix (¿sin conexión a internet?)." >&2
          exit 1
        fi

        echo "⚙️ Evaluando nueva generación de NixOS..."
        rm -f "$RESULT_LINK"
        if ! ${pkgs.nix}/bin/nix build "$FLAKE_CACHE#nixosConfigurations.loon-laptop.config.system.build.toplevel" --out-link "$RESULT_LINK" >/dev/null 2>&1; then
          echo "⚠️ Error al evaluar la nueva generación." >&2
          exit 1
        fi

        echo "📊 Comparando versiones de paquetes..."
        ${pkgs.nvd}/bin/nvd diff /run/current-system "$RESULT_LINK" > "$CACHE_DIR/diff.raw"

        ${pkgs.python3}/bin/python3 ${pythonScript} parse
        echo "✅ Verificación completada."
        echo ""
        if [ -f "$CACHE_DIR/summary.txt" ]; then
          cat "$CACHE_DIR/summary.txt"
        fi
        ;;

      banner)
        ${pkgs.python3}/bin/python3 ${pythonScript} banner
        ;;

      count)
        if [ -f "$CACHE_DIR/count" ]; then
          cat "$CACHE_DIR/count"
        else
          echo "0"
        fi
        ;;

      show|list|*)
        if [ -f "$CACHE_DIR/summary.txt" ]; then
          cat "$CACHE_DIR/summary.txt"
        else
          echo "No se han verificado actualizaciones aún."
          echo "Ejecuta 'nix-updates check' para realizar la primera búsqueda."
        fi
        ;;
    esac
  '';
in
script
