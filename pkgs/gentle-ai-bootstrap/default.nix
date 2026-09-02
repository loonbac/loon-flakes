{ writeShellApplication
, writeText
, coreutils
, nodejs
, gentleAi
, engram
, piStack
}:

let
  # These are the packages Pi loads from its user configuration. Their
  # versions are also recorded in package.json/package-lock.json.
  piPackages = [
    "npm:gentle-pi@2.3.0"
    "npm:gentle-engram@0.1.10"
    "npm:@tintinweb/pi-subagents@0.19.0"
    "npm:@juicesharp/rpiv-ask-user-question@2.7.1"
    "npm:pi-web-access@0.27.0"
    "npm:@juicesharp/rpiv-todo@2.7.1"
    "npm:pi-btw@0.4.1"
    "npm:pi-commandcode-provider@0.6.0"
    "npm:pi-mcp-adapter@2.31.0"
  ];

  piPackageNames = [
    "gentle-pi"
    "gentle-engram"
    "@tintinweb/pi-subagents"
    "@juicesharp/rpiv-ask-user-question"
    "pi-web-access"
    "@juicesharp/rpiv-todo"
    "pi-btw"
    "pi-commandcode-provider"
    "pi-mcp-adapter"
  ];

  # Keep the old extension managed long enough to remove it from existing
  # settings.json files during the one-time migration. It is never installed
  # again and is not allowed to coexist with the replacement.
  retiredPiPackageNames = [ "pi-subagents-j0k3r" ];

  manifest = writeText "gentle-ai-manifest.json" (builtins.toJSON {
    inherit piPackages piPackageNames;
    managedPiPackageNames = piPackageNames ++ retiredPiPackageNames;
    gentleAiVersion = gentleAi.version;
    engramVersion = engram.version;
    piVersion = piStack.version;
  });

  mcpConfig = writeText "mcp.json" (builtins.toJSON {
    mcpServers.engram = {
      command = "${engram}/bin/engram";
      args = [ "mcp" "--tools=agent" ];
      lifecycle = "lazy";
      directTools = false;
    };
  });

  mergeSettings = writeText "merge-pi-settings.mjs" ''
    import fs from "node:fs";

    const [settingsPath, manifestPath] = process.argv.slice(2);
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    const settings = fs.existsSync(settingsPath)
      ? JSON.parse(fs.readFileSync(settingsPath, "utf8"))
      : {};

    function packageName(spec) {
      const value = String(spec).replace(/^npm:/, "");
      if (value.startsWith("@")) {
        const slash = value.indexOf("/");
        const at = value.indexOf("@", slash);
        return at < 0 ? value : value.slice(0, at);
      }
      // A package can be kept in settings as a local path. Treat its final
      // path segment as the package name so a local checkout cannot coexist
      // with the Nix-managed npm package of the same name.
      const pathSegments = value.split("/").filter(Boolean);
      const packageSpec = value.includes("/") ? (pathSegments.at(-1) ?? value) : value;
      const at = packageSpec.indexOf("@");
      return at < 0 ? packageSpec : packageSpec.slice(0, at);
    }

    const managed = new Set(manifest.managedPiPackageNames);
    const existing = Array.isArray(settings.packages) ? settings.packages : [];
    settings.packages = existing
      .filter((spec) => !managed.has(packageName(spec)))
      .concat(manifest.piPackages);

    const previous = fs.existsSync(settingsPath) ? fs.statSync(settingsPath) : null;
    const mode = previous ? previous.mode & 0o777 : 0o644;
    const temporary = `''${settingsPath}.nix-tmp-''${process.pid}`;
    fs.writeFileSync(temporary, `''${JSON.stringify(settings, null, 2)}\n`, { mode });
    fs.renameSync(temporary, settingsPath);
    fs.chmodSync(settingsPath, mode);
  '';

  mergeState = writeText "merge-gentle-ai-state.mjs" ''
    import fs from "node:fs";

    const [statePath] = process.argv.slice(2);
    const state = fs.existsSync(statePath)
      ? JSON.parse(fs.readFileSync(statePath, "utf8"))
      : {};

    for (const key of ["installed_agents", "components"]) {
      const wanted = key === "installed_agents" ? ["pi"] : ["engram"];
      const current = Array.isArray(state[key]) ? state[key] : [];
      state[key] = [...new Set([...current, ...wanted])];
    }
    state.selection_configured = true;
    state.preset = "full-gentleman";
    state.community_tools_configured = true;
    state.persona = "gentleman";

    const previous = fs.existsSync(statePath) ? fs.statSync(statePath) : null;
    const mode = previous ? previous.mode & 0o777 : 0o600;
    const temporary = `''${statePath}.nix-tmp-''${process.pid}`;
    fs.writeFileSync(temporary, `''${JSON.stringify(state, null, 2)}\n`, { mode });
    fs.renameSync(temporary, statePath);
    fs.chmodSync(statePath, mode);
  '';
in

writeShellApplication {
  name = "gentle-ai-bootstrap";
  runtimeInputs = [ coreutils nodejs gentleAi ];

  text = ''
    agent_dir="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    npm_node_modules="$agent_dir/npm/node_modules"
    state_path="$HOME/.gentle-ai/state.json"
    repo_dir="''${GENTLE_AI_NIXOS_REPO:-$HOME/.nixos}"
    stack_node_modules="${piStack}/lib/pi/node_modules"
    backup_dir="$agent_dir/backups/nix-gentle-ai/$(date +%Y%m%d%H%M%S)"

    mkdir -p "$npm_node_modules" "$HOME/.gentle-ai"

    # A fresh machine gets RDD enabled once. An explicit later `disable` is
    # respected because an existing rdd_mode field is never overwritten here.
    if [ -d "$repo_dir/.git" ]; then
      if [ ! -f "$state_path" ] || ! node -e '
        const fs = require("node:fs");
        const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.exit(Object.prototype.hasOwnProperty.call(state, "rdd_mode") ? 0 : 1);
      ' "$state_path"; then
        gentle-ai review mode enable --scope global --cwd "$repo_dir" >/dev/null
      fi
    fi

    link_package() {
      package_name="$1"
      source="$stack_node_modules/$package_name"
      destination="$npm_node_modules/$package_name"

      if [ ! -e "$source" ]; then
        echo "Missing Nix package in Pi stack: $package_name" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$destination")"

      if [ -L "$destination" ] && [ "$(readlink -f "$destination")" = "$source" ]; then
        return
      fi
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        mkdir -p "$(dirname "$backup_dir/$package_name")"
        mv "$destination" "$backup_dir/$package_name"
      fi
      ln -s "$source" "$destination"
    }

    for package_name in \
      gentle-pi \
      gentle-engram \
      @tintinweb/pi-subagents \
      @juicesharp/rpiv-ask-user-question \
      pi-web-access \
      @juicesharp/rpiv-todo \
      pi-btw \
      pi-commandcode-provider \
      pi-mcp-adapter; do
      link_package "$package_name"
    done

    # Remove the previous subagent implementation from the mutable Pi tree.
    # Keep it recoverable in the same backup area used for other migrations.
    retire_package() {
      package_name="$1"
      destination="$npm_node_modules/$package_name"
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        mkdir -p "$(dirname "$backup_dir/$package_name")"
        mv "$destination" "$backup_dir/$package_name"
      fi
    }
    retire_package "pi-subagents-j0k3r"

    # Retire the old mutable executables so doctor and PATH cannot select a
    # second Gentle-AI/Pi/Engram implementation. They remain recoverable.
    retire_binary() {
      legacy_path="$1"
      if [ -e "$legacy_path" ] || [ -L "$legacy_path" ]; then
        mkdir -p "$backup_dir/legacy-binaries"
        mv "$legacy_path" "$backup_dir/legacy-binaries/$(basename "$legacy_path")"
      fi
    }
    retire_binary "$HOME/go/bin/gentle-ai"
    retire_binary "$HOME/.local/bin/engram"
    retire_binary "$HOME/.npm-global/bin/pi"

    settings_path="$agent_dir/settings.json"
    if [ ! -f "$settings_path" ]; then
      printf '%s\n' '{}' > "$settings_path"
    fi
    node "${mergeSettings}" "$settings_path" "${manifest}"

    mcp_path="$agent_dir/mcp.json"
    if ! [ -L "$mcp_path" ] && [ -e "$mcp_path" ]; then
      mkdir -p "$(dirname "$backup_dir/mcp.json")"
      mv "$mcp_path" "$backup_dir/mcp.json"
    elif [ -L "$mcp_path" ] && [ "$(readlink -f "$mcp_path")" = "${mcpConfig}" ]; then
      mcp_path=""
    fi
    if [ -n "$mcp_path" ]; then
      ln -s "${mcpConfig}" "$mcp_path"
    fi

    node "${mergeState}" "$state_path"
    echo "Gentle-AI, Pi y Engram quedaron inicializados desde el store Nix (sin descargas npm)."
  '';
}
