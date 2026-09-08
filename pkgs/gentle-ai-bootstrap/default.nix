{ writeShellApplication
, writeText
, coreutils
, git
, nodejs
, gentleAi
, engram
, piStack
}:

let
  # These are the packages Pi loads from its user configuration. Their
  # versions are also recorded in package.json/package-lock.json.
  piPackages = [
    "npm:pi-antigravity@0.7.2"
    "npm:better-claude-code-ui@0.1.7"
    "${piStack}/lib/pi/node_modules/gentle-pi"
    "npm:gentle-engram@0.1.10"
    "npm:@juicesharp/rpiv-ask-user-question@2.7.1"
    "npm:pi-web-access@0.27.0"
    "npm:pi-btw@0.4.1"
    "npm:pi-commandcode-provider@0.6.0"
    "npm:pi-mcp-adapter@2.31.0"
  ];

  piPackageNames = [
    "pi-antigravity"
    "better-claude-code-ui"
    "gentle-pi"
    "gentle-engram"
    "@juicesharp/rpiv-ask-user-question"
    "pi-web-access"
    "pi-btw"
    "pi-commandcode-provider"
    "pi-mcp-adapter"
  ];

  piSettings = {
    defaultModel = "deepseek-v4-flash";
    defaultProjectTrust = "always";
    defaultProvider = "opencode-go";
    defaultThinkingLevel = "high";
    hideThinkingBlock = false;
    markdown.mermaid = "streaming";
    quietStartup = true;
    showHardwareCursor = true;
    theme = "claude-code-dark-ansi";
    tuiMode = "fullscreen";
  };

  piModelProviders = {
    "ollama-vast" = {
      baseUrl = "http://localhost:11434/v1";
      api = "openai-completions";
      apiKey = "ollama";
      compat = {
        supportsDeveloperRole = false;
        supportsReasoningEffort = false;
        maxTokensField = "max_tokens";
      };
      models = [
        {
          id = "qwen38-27b-q5-32k";
          name = "Qwen3.8 27B Uncensored Q5";
          reasoning = false;
          input = [ "text" ];
          contextWindow = 32768;
          maxTokens = 16384;
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        }
      ];
    };
  };

  subagentModelProfiles = {
    gentle-ai-explore = { model = "antigravity/gemini-3.8-flash"; effort = "medium"; };
    gentle-ai-verify = { model = "openai-codex/gpt-5.6-terra"; effort = "high"; };
    gentle-ai-worker = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    jd-fix-agent = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    jd-judge-a = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    jd-judge-b = { model = "antigravity/claude-opus-4-6"; effort = "max"; };
    pi-btw = { model = "commandcode/deepseek/deepseek-v4-flash"; effort = "max"; };
    review-readability = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    review-reliability = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    review-resilience = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    review-risk = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-apply = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-archive = { model = "antigravity/gemini-3.8-flash"; effort = "medium"; };
    sdd-design = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-explore = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-init = { model = "antigravity/gemini-3.8-flash"; effort = "medium"; };
    sdd-onboard = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-proposal = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-research = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-spec = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-status = { model = "antigravity/gemini-3.8-flash"; effort = "low"; };
    sdd-sync = { model = "antigravity/gemini-3.8-flash"; effort = "medium"; };
    sdd-tasks = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-verify = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
  };

  gentleModelProfiles =
    builtins.mapAttrs (_: profile: {
      inherit (profile) model;
      thinking = profile.effort;
    }) subagentModelProfiles
    // {
      review-refuter = { model = "commandcode/deepseek/deepseek-v4-flash"; };
      review-validator = { model = "commandcode/deepseek/deepseek-v4-flash"; };
    };

  gentlePortableConfig = {
    backgroundSubagents = {
      schema = "gentle-pi.background-subagents/v1";
      policy = "on";
    };
    banner = {
      color = "pink";
      showRose = false;
      showTextLogo = false;
    };
    persona.mode = "neutral";
  };

  # Keep replaced extensions managed long enough to remove them from existing
  # settings.json files during the migration. Gentle Agents and Gentle Todo
  # are built into the pinned gentle-pi main snapshot.
  retiredPiPackageNames = [
    "pi-subagents-j0k3r"
    "@tintinweb/pi-subagents"
    "@juicesharp/rpiv-todo"
  ];

  manifest = writeText "gentle-ai-manifest.json" (builtins.toJSON {
    inherit
      piPackages
      piPackageNames
      piSettings
      piModelProviders
      subagentModelProfiles
      gentleModelProfiles
      gentlePortableConfig
      ;
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

    // La configuración portable del flake es autoritativa. Credenciales,
    // modelos descubiertos y sesiones viven en archivos separados.
    Object.assign(settings, manifest.piSettings);

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
    const sortKeys = (value) => {
      if (Array.isArray(value)) return value.map(sortKeys);
      if (value && typeof value === "object") {
        return Object.fromEntries(
          Object.keys(value).sort().map((key) => [key, sortKeys(value[key])]),
        );
      }
      return value;
    };
    fs.writeFileSync(temporary, `''${JSON.stringify(sortKeys(settings), null, 2)}\n`, { mode });
    fs.renameSync(temporary, settingsPath);
    fs.chmodSync(settingsPath, mode);
  '';

  mergeModels = writeText "merge-pi-models.mjs" ''
    import fs from "node:fs";

    const [modelsPath, manifestPath] = process.argv.slice(2);
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    const models = fs.existsSync(modelsPath)
      ? JSON.parse(fs.readFileSync(modelsPath, "utf8"))
      : {};

    if (!models.providers || typeof models.providers !== "object" || Array.isArray(models.providers)) {
      models.providers = {};
    }
    Object.assign(models.providers, manifest.piModelProviders);

    const previous = fs.existsSync(modelsPath) ? fs.statSync(modelsPath) : null;
    const mode = previous ? previous.mode & 0o777 : 0o600;
    const temporary = `''${modelsPath}.nix-tmp-''${process.pid}`;
    const sortKeys = (value) => {
      if (Array.isArray(value)) return value.map(sortKeys);
      if (value && typeof value === "object") {
        return Object.fromEntries(
          Object.keys(value).sort().map((key) => [key, sortKeys(value[key])]),
        );
      }
      return value;
    };
    fs.writeFileSync(temporary, `''${JSON.stringify(sortKeys(models), null, 2)}\n`, { mode });
    fs.renameSync(temporary, modelsPath);
    fs.chmodSync(modelsPath, mode);
  '';

  syncAgentRouting = writeText "sync-pi-agent-routing.mjs" ''
    import crypto from "node:crypto";
    import fs from "node:fs";
    import path from "node:path";

    const [agentDir, manifestPath] = process.argv.slice(2);
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    const profiles = manifest.subagentModelProfiles;
    const configPath = path.join(agentDir, "subagents.json");

    function writeJson(targetPath, value) {
      fs.mkdirSync(path.dirname(targetPath), { recursive: true });
      const temporary = `''${targetPath}.nix-tmp-''${process.pid}`;
      fs.writeFileSync(temporary, `''${JSON.stringify(value, null, 2)}\n`, { mode: 0o644 });
      fs.renameSync(temporary, targetPath);
      fs.chmodSync(targetPath, 0o644);
    }

    writeJson(configPath, { model_profiles: profiles });

    const gentleDir = path.join(path.dirname(agentDir), "gentle-ai");
    writeJson(path.join(gentleDir, "models.json"), manifest.gentleModelProfiles);
    writeJson(
      path.join(gentleDir, "background-subagents.json"),
      manifest.gentlePortableConfig.backgroundSubagents,
    );
    writeJson(path.join(gentleDir, "banner.json"), manifest.gentlePortableConfig.banner);
    writeJson(path.join(gentleDir, "persona.json"), manifest.gentlePortableConfig.persona);

    for (const [name, profile] of Object.entries(profiles)) {
      const agentPath = path.join(agentDir, "agents", `''${name}.md`);
      if (!fs.existsSync(agentPath)) continue;

      const lines = fs.readFileSync(agentPath, "utf8").split("\n");
      const closing = lines.indexOf("---", 1);
      if (lines[0] !== "---" || closing < 0) continue;

      const frontmatter = lines
        .slice(1, closing)
        .filter((line) => !/^(model|thinking):/.test(line));
      const description = frontmatter.findIndex((line) => line.startsWith("description:"));
      const insertion = description < 0 ? frontmatter.length : description + 1;
      frontmatter.splice(
        insertion,
        0,
        `model: ''${profile.model}`,
        `thinking: ''${profile.effort}`,
      );

      const updated = ["---", ...frontmatter, "---", ...lines.slice(closing + 1)].join("\n");
      fs.writeFileSync(agentPath, updated, { mode: 0o644 });
    }

    // gentle-pi uses this manifest to distinguish its managed assets from
    // user-created files. Record the final contents after adding model routes.
    const managedAssets = {};
    for (const relativeDir of ["agents", "chains", "gentle-ai/support"]) {
      const directory = path.join(agentDir, relativeDir);
      if (!fs.existsSync(directory)) continue;
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (!entry.isFile() || !entry.name.endsWith(".md")) continue;
        if (relativeDir === "agents" && entry.name === "pi-btw.md") continue;
        const relativePath = path.posix.join(relativeDir, entry.name);
        const contents = fs.readFileSync(path.join(directory, entry.name));
        managedAssets[relativePath] = crypto.createHash("sha256").update(contents).digest("hex");
      }
    }
    writeJson(
      path.join(agentDir, "gentle-ai", "managed-assets.json"),
      { schemaVersion: 1, assets: managedAssets },
    );
  '';

  piBtwAgent = writeText "pi-btw.md" ''
    ---
    name: pi-btw
    description: Dedicated model route for Pi BTW side questions.
    model: commandcode/deepseek/deepseek-v4-flash
    thinking: max
    ---

    This agent entry is the gentle-pi model route for the `@narumitw/pi-btw` `/btw` extension.
    Choose its model and thinking level from `/gentle:models`; pi-btw reads the resulting route from gentle-pi.
  '';

  appendSystemExtra = writeText "pi-append-system-extra.md" ''
    ## Investigación web

    - Para leer cualquier página pública, usar `dataimpulse_fetch_page` (la tool MCP `fetch_page`) en vez de WebFetch/fetch_content.
    - Excepción: si es documentación pública que no bloquea, WebFetch/fetch_content es más rápido y no consume gigas. El proxy es para lo que bloquea o lo que cambia por región.
    - Si el contenido depende del país (precios, stock, disponibilidad, búsquedas), pasar `country` explícito siempre. Nunca asumir el país por defecto.
    - Si hay más de un request al mismo sitio (paginado, login, flujo de 2 pasos), usar el mismo `session` en todos. Una IP por tarea, no una IP por request.
    - Ante un 403 no reintentar igual: cambiar de país o fijar `session`.
    - Ante un 503 `NO_RAY`, sacar el targeting de ciudad y dejar solo país.
    - No configurar `HTTP_PROXY` ni `HTTPS_PROXY` globalmente: el proxy se usa únicamente dentro de `dataimpulse_fetch_page` y `dataimpulse_check_exit_ip`.
  '';

  rddRouting = writeText "pi-rdd-routing.md" ''
    ## Implementation Routing

    Route work for the requested outcome with the smallest useful topology. Every change takes exactly one implementation route: direct inline, delegated direct, or optional SDD.

    - **Direct inline:** decide or verify from 1–3 files inline. Keep one mechanical, already-understood file change inline only when it needs no research and has no unresolved design decision.
    - **Delegated direct:** delegate one narrow exploration when understanding needs 4+ files; delegate one writer for 2+ non-trivial files. Reading that prepares a write and broad research also delegate.
    - **Optional SDD:** propose SDD only when durable proposal, spec, design, and tasks would materially reduce substantial ambiguity. SDD is selected only by an explicit request or an accepted proposal.
    - File count, changed lines, size, or perceived risk alone never selects SDD and never forces a heavier route.
    - These are implementation routes, not a ban on per-action delegation. Tests, builds, installs, and review actors may still use fresh workers without changing the selected route.
    - Direct and delegated work never create SDD artifacts, prompts, phase attempts, or synthetic SDD runs.

    ### Receipt-driven development is user-owned

    The user controls receipt-driven development with a kill switch: `gentle-ai review mode enable|disable|status`.

    - `status` is read-only. It reports the deciding source and the effective mode, and changes nothing.
    - When the user asks to stop using receipt-driven development, run `disable`. Do not argue, do not work around it, and do not propose alternatives first.
    - While it is disabled, keep implementing organically through direct inline, delegated direct, or optional SDD: do not start reviews, do not retry, do not reactivate it, and do not fall back to any retired path.
    - Delivery under a disabled switch follows ordinary repository policy and reports `disabled/unmanaged`, never a fabricated approval.
    - Never enable receipt-driven development on the user's behalf unless the user explicitly asks for it.
  '';

  mergeAppendSystem = writeText "merge-pi-append-system.mjs" ''
    import fs from "node:fs";

    const [targetPath, extraPath, routingPath, statePath] = process.argv.slice(2);
    const begin = "<!-- nixos:pi-portable-instructions -->";
    const end = "<!-- /nixos:pi-portable-instructions -->";
    const routingBegin = "<!-- gentle-ai:agent-routing -->";
    const routingEnd = "<!-- /gentle-ai:agent-routing -->";
    const extra = fs.readFileSync(extraPath, "utf8").trim();
    const routing = fs.readFileSync(routingPath, "utf8").trim();
    const state = fs.existsSync(statePath)
      ? JSON.parse(fs.readFileSync(statePath, "utf8"))
      : {};
    let content = fs.existsSync(targetPath) ? fs.readFileSync(targetPath, "utf8") : "";

    content = content.replace(new RegExp(`\\n?''${begin}[\\s\\S]*?''${end}\\n?`, "g"), "\n");
    content = content.replace(
      new RegExp(`\\n?''${routingBegin}[\\s\\S]*?''${routingEnd}\\n?`, "g"),
      "\n",
    );
    const legacyHeading = content.indexOf("\n## Investigación web\n");
    if (legacyHeading >= 0) content = content.slice(0, legacyHeading);
    content = content.trimEnd();

    const blocks = [];
    if (state.rdd_mode === "on") {
      blocks.push(`''${routingBegin}\n''${routing}\n''${routingEnd}`);
    }
    blocks.push(`''${begin}\n''${extra}\n''${end}`);
    const managed = blocks.join("\n\n");
    fs.writeFileSync(targetPath, `''${content ? `''${content}\n\n` : ""}''${managed}\n`, { mode: 0o644 });
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
  runtimeInputs = [ coreutils git nodejs gentleAi ];

  text = ''
    agent_dir="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    npm_node_modules="$agent_dir/npm/node_modules"
    state_path="$HOME/.gentle-ai/state.json"
    repo_dir="''${GENTLE_AI_NIXOS_REPO:-$HOME/.nixos}"
    stack_node_modules="${piStack}/lib/pi/node_modules"
    backup_dir="$agent_dir/backups/nix-gentle-ai/$(date +%Y%m%d%H%M%S)"

    mkdir -p "$npm_node_modules" "$HOME/.gentle-ai"

    # A fresh machine gets RDD enabled once. Reconcile its managed prompt when
    # it is already on, while respecting an explicit later `disable`.
    if [ -d "$repo_dir/.git" ]; then
      if [ ! -f "$state_path" ] || node -e '
        const fs = require("node:fs");
        const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.exit(!Object.prototype.hasOwnProperty.call(state, "rdd_mode") || state.rdd_mode === "on" ? 0 : 1);
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
      pi-antigravity \
      better-claude-code-ui \
      gentle-pi \
      gentle-engram \
      @juicesharp/rpiv-ask-user-question \
      pi-web-access \
      pi-btw \
      pi-commandcode-provider \
      pi-mcp-adapter; do
      link_package "$package_name"
    done

    link_skill() {
      skill_name="$1"
      source="${piStack}/share/pi/skills/$skill_name"
      destination="$agent_dir/skills/$skill_name"

      if [ ! -d "$source" ]; then
        echo "Missing Nix-managed Pi skill: $skill_name" >&2
        exit 1
      fi
      mkdir -p "$agent_dir/skills"

      if [ -L "$destination" ] && [ "$(readlink -f "$destination")" = "$source" ]; then
        return
      fi
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        mkdir -p "$backup_dir/skills"
        mv "$destination" "$backup_dir/skills/$skill_name"
      fi
      ln -s "$source" "$destination"
    }

    for skill_name in \
      agents-sdk \
      cloudflare \
      cloudflare-email-service \
      cloudflare-one \
      cloudflare-one-migrations \
      durable-objects \
      impeccable \
      sandbox-migrate-to-next \
      sandbox-next \
      sandbox-stable \
      turnstile-spin \
      web-perf \
      workers-best-practices \
      wrangler; do
      link_skill "$skill_name"
    done

    # Remove the replaced subagent/todo implementations from the mutable Pi
    # tree. Keep them recoverable in the same backup area used for migrations.
    retire_package() {
      package_name="$1"
      destination="$npm_node_modules/$package_name"
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        mkdir -p "$(dirname "$backup_dir/$package_name")"
        mv "$destination" "$backup_dir/$package_name"
      fi
    }
    retire_package "pi-subagents-j0k3r"
    retire_package "@tintinweb/pi-subagents"
    retire_package "@juicesharp/rpiv-todo"

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
    retire_binary "$HOME/.local/bin/gga"
    retire_binary "$HOME/.npm-global/bin/pi"

    # A development-binary selector points outside the Nix store and makes a
    # clean host behave differently. Retire it like the mutable executables.
    dev_binary_config="$HOME/.pi/gentle-ai/dev-binary.json"
    if [ -e "$dev_binary_config" ] || [ -L "$dev_binary_config" ]; then
      mkdir -p "$backup_dir/gentle-ai"
      mv "$dev_binary_config" "$backup_dir/gentle-ai/dev-binary.json"
    fi

    settings_path="$agent_dir/settings.json"
    if [ ! -f "$settings_path" ]; then
      printf '%s\n' '{}' > "$settings_path"
    fi
    node "${mergeSettings}" "$settings_path" "${manifest}"

    # Reconcile only Nix-managed providers and preserve any local providers.
    node "${mergeModels}" "$agent_dir/models.json" "${manifest}"

    # Install every managed Gentle Pi agent, chain and support contract from
    # the pinned store closure. This makes an empty home fully functional.
    mkdir -p "$agent_dir/agents" "$agent_dir/chains" "$agent_dir/gentle-ai/support"
    cp "$stack_node_modules/gentle-pi/assets/agents/"*.md "$agent_dir/agents/"
    cp "$stack_node_modules/gentle-pi/assets/chains/"*.md "$agent_dir/chains/"
    cp "$stack_node_modules/gentle-pi/assets/support/"*.md "$agent_dir/gentle-ai/support/"
    cp ${piBtwAgent} "$agent_dir/agents/pi-btw.md"
    chmod 644 \
      "$agent_dir/agents/"*.md \
      "$agent_dir/chains/"*.md \
      "$agent_dir/gentle-ai/support/"*.md
    node "${syncAgentRouting}" "$agent_dir" "${manifest}"

    node "${mergeAppendSystem}" \
      "$agent_dir/APPEND_SYSTEM.md" \
      "${appendSystemExtra}" \
      "${rddRouting}" \
      "$state_path"

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
