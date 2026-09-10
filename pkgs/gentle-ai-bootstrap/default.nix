{ writeShellApplication
, writeText
, coreutils
, bash
, git
, gzip
, nodejs
, libnotify
, pipewire
, piLauncher
, gentleAiLauncher
, engramLauncher
, betterClaudeCodeUi
}:

let
  # Nix owns the desired package set, while Pi owns the mutable versions.
  # Unversioned npm specs make `pi update --extensions` the single update lane.
  piPackages = [
    "npm:pi-antigravity"
    "@HOME@/.local/share/loon-pi-packages/pi-antigravity-alt"
    "@HOME@/.local/share/loon-pi-packages/better-claude-code-ui"
    "npm:gentle-pi"
    "npm:gentle-engram"
    "npm:@juicesharp/rpiv-ask-user-question"
    "npm:pi-web-access"
    "npm:pi-btw"
    "npm:pi-commandcode-provider"
    "npm:pi-mcp-adapter"
  ];

  piPackageNames = [
    "pi-antigravity"
    "pi-antigravity-alt"
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
    defaultModel = "gpt-5.6-sol";
    defaultProjectTrust = "always";
    defaultProvider = "openai-codex";
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
    gentle-ai-verify = { model = "opencode-go/deepseek-v4-flash"; effort = "medium"; };
    gentle-ai-worker = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    jd-fix-agent = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    jd-judge-a = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    jd-judge-b = { model = "antigravity/claude-opus-4-6"; effort = "xhigh"; };
    pi-btw = { model = "opencode-go/deepseek-v4-flash"; effort = "xhigh"; };
    review-readability = { model = "opencode-go/deepseek-v4-flash"; effort = "medium"; };
    review-reliability = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    review-resilience = { model = "opencode-go/deepseek-v4-flash"; effort = "high"; };
    review-risk = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-apply = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-archive = { model = "opencode-go/deepseek-v4-flash"; effort = "medium"; };
    sdd-design = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-explore = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-init = { model = "opencode-go/deepseek-v4-flash"; effort = "medium"; };
    sdd-onboard = { model = "antigravity/gemini-3.8-flash"; effort = "medium"; };
    sdd-proposal = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-research = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
    sdd-spec = { model = "antigravity/gemini-3.8-flash"; effort = "high"; };
    sdd-status = { model = "opencode-go/deepseek-v4-flash"; effort = "low"; };
    sdd-sync = { model = "opencode-go/deepseek-v4-flash"; effort = "medium"; };
    sdd-tasks = { model = "antigravity/gemini-3.8-flash"; effort = "medium"; };
    sdd-verify = { model = "openai-codex/gpt-5.6-sol"; effort = "high"; };
  };

  gentleModelProfiles =
    builtins.mapAttrs (_: profile: {
      inherit (profile) model;
      thinking = profile.effort;
    }) subagentModelProfiles
    // {
      review-refuter = { model = "openai-codex/gpt-5.6-sol"; thinking = "high"; };
      review-validator = { model = "openai-codex/gpt-5.6-sol"; thinking = "high"; };
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
  });

  mcpConfig = writeText "mcp.json" (builtins.toJSON {
    mcpServers.engram = {
      command = "${engramLauncher}/bin/engram";
      args = [ "mcp" "--tools=agent" ];
      lifecycle = "lazy";
      directTools = false;
    };
  });

  antigravityQuotaFallback = ../pi/extensions/antigravity-quota-fallback.ts;
  antigravityAliasSchema = 1;
  # Pi's own ui.notify() is an in-terminal toast. Desktop alerts are exposed
  # separately through lifecycle events, so bridge every blocking extension
  # prompt and every settled run to SwayNC and play an explicit PipeWire sound.
  # This deliberately does not depend on the terminal bell: Ghostty ships with
  # audio bells disabled, and Pi may also be run from another terminal.
  piNotifications = writeText "loon-pi-notifications.ts" ''
    import { spawn } from "node:child_process";
    import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

    const NOTIFY_SEND = "${libnotify}/bin/notify-send";
    const PW_PLAY = "${pipewire}/bin/pw-play";
    const NOTIFICATION_SOUND = "${../pi/assets/snd_shineselect.wav}";
    const PROMPT_DEDUP_MS = 2500;
    const IS_GENTLE_SUBAGENT = process.env.GENTLE_PI_AGENTS_CHILD === "1";
    const GENTLE_SUBAGENT_PROMPT_PREFIX = "❀ ";

    type UnknownRecord = Record<string, unknown>;

    function isRecord(value: unknown): value is UnknownRecord {
      return typeof value === "object" && value !== null && !Array.isArray(value);
    }

    function clean(value: unknown, fallback: string, limit = 220): string {
      if (typeof value !== "string") return fallback;
      const text = value.replace(/[\x00-\x1f\x7f]+/g, " ").replace(/\s+/g, " ").trim();
      if (!text) return fallback;
      return text.length <= limit ? text : text.slice(0, limit - 1) + "…";
    }

    function launch(command: string, args: string[]): void {
      try {
        const child = spawn(command, args, { detached: true, stdio: "ignore" });
        child.on("error", () => {});
        child.unref();
      } catch {
        // Notifications are best effort and must never interrupt Pi.
      }
    }

    function desktopNotification(title: string, body: string, icon: string): void {
      launch(NOTIFY_SEND, [
        "--app-name=Pi",
        "--urgency=normal",
        "--expire-time=10000",
        "--icon=" + icon,
        title,
        body,
      ]);
    }

    function play(sound: string): void {
      launch(PW_PLAY, ["--media-role=Notification", "--volume=0.15", sound]);
    }

    export default function loonPiNotifications(pi: ExtensionAPI): void {
      // Gentle Agents launches isolated Pi RPC processes which load the same
      // global extensions. Their lifecycle is internal to the main session:
      // never alert when a child settles. Questions relayed by a child are
      // rendered through the main Pi UI and are covered there instead.
      if (IS_GENTLE_SUBAGENT) return;

      let context: ExtensionContext | undefined;
      let lastPromptAt = 0;
      let promptActive = false;
      let notifyWhenSettled = false;

      pi.on("session_start", (_event, ctx) => {
        context = ctx;
        lastPromptAt = 0;
        promptActive = false;
        notifyWhenSettled = false;
      });

      const prompt = (
        body: unknown,
        options: { allowIdle?: boolean; title?: string; icon?: string } = {},
      ): void => {
        // Ignore dialogs opened manually while Pi is idle (settings, model
        // picker, plugin browsers, etc.). An RPC question relayed by a Gentle
        // subagent is the exception: the parent can be idle while the child
        // is blocked waiting for its answer.
        if (!context?.hasUI || (context.isIdle() && !options.allowIdle)) return;
        const now = Date.now();
        if (now - lastPromptAt < PROMPT_DEDUP_MS) return;
        lastPromptAt = now;
        desktopNotification(
          options.title ?? "Pi necesita tu respuesta",
          clean(body, "Hay una pregunta esperando en la terminal."),
          options.icon ?? "dialog-question",
        );
        play(NOTIFICATION_SOUND);
      };

      // Unlike automatic custom-message turns (notably gentle-agents.result),
      // a normal main-session request passes through before_agent_start. Keep
      // this marker across retries, compaction and queued continuations until
      // the one final agent_settled event.
      pi.on("before_agent_start", (_event, ctx) => {
        context = ctx;
        notifyWhenSettled = true;
      });

      // Pi 0.85+ emits this for every select/confirm/input/editor/custom UI,
      // including prompts created by third-party plugins.
      pi.on("ui_prompt_start", (event, ctx) => {
        context = ctx;
        promptActive = true;
        const fromSubagent = typeof event.title === "string"
          && event.title.startsWith(GENTLE_SUBAGENT_PROMPT_PREFIX);
        const body = fromSubagent
          ? event.title?.slice(GENTLE_SUBAGENT_PROMPT_PREFIX.length)
          : event.title;
        prompt(body, { allowIdle: fromSubagent });
      });
      pi.on("ui_prompt_end", (_event, ctx) => {
        context = ctx;
        promptActive = false;
      });

      // Compatibility and richer text for the two installed question tools.
      // Their event fires before ui_prompt_start, which the dedupe window then
      // suppresses, so each prompt still produces exactly one alert.
      pi.events.on("rpiv:ask-user:prompt", (payload) => {
        const questions = isRecord(payload) && Array.isArray(payload.questions)
          ? payload.questions
          : [];
        const first = questions.find(isRecord);
        prompt(first?.question, { title: "Pi tiene una pregunta" });
      });
      pi.events.on("gentle-pi:ask-user-choice:blocked", (payload) => {
        if (isRecord(payload) && payload.active === true) {
          prompt("Hay una elección esperando en la terminal.", {
            title: "Pi necesita una elección",
          });
        }
      });
      pi.events.on("pi-permission-system:permission-request", (payload) => {
        if (isRecord(payload) && payload.state === "waiting") {
          prompt(payload.message, {
            title: "Pi solicita confirmación",
            icon: "dialog-warning",
          });
        }
      });

      // agent_settled is the correct full-request boundary: unlike agent_end,
      // it does not fire before automatic retries, compaction or follow-ups.
      pi.on("agent_settled", (_event, ctx) => {
        context = ctx;
        const shouldNotify = notifyWhenSettled && !promptActive;
        notifyWhenSettled = false;
        if (!shouldNotify) return;
        desktopNotification("Pi terminó", "La tarea principal terminó y espera instrucciones.", "dialog-information");
        play(NOTIFICATION_SOUND);
      });
    }
  '';

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
    const desiredPackages = manifest.piPackages
      .map((spec) => String(spec).replace(/^@HOME@/, process.env.HOME ?? ""))
      // Generated local packages are added on the second reconciliation after
      // their upstream npm package has been installed and cloned.
      .filter((spec) => !spec.startsWith("/") || fs.existsSync(spec));
    settings.packages = existing
      .filter((spec) => !managed.has(packageName(spec)))
      .concat(desiredPackages);

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

  mergeNpmPolicy = writeText "merge-pi-npm-policy.mjs" ''
    import fs from "node:fs";
    import path from "node:path";

    const [packageJsonPath] = process.argv.slice(2);
    const packageJson = fs.existsSync(packageJsonPath)
      ? JSON.parse(fs.readFileSync(packageJsonPath, "utf8"))
      : { name: "pi-extensions", private: true };

    // npm 11 blocks lifecycle scripts until they are explicitly approved.
    // gentle-pi's postinstall is the supported installer for its versioned,
    // checksum-verified Gentle AI binary, so approve that package alone.
    if (!packageJson.allowScripts || typeof packageJson.allowScripts !== "object" || Array.isArray(packageJson.allowScripts)) {
      packageJson.allowScripts = {};
    }
    packageJson.allowScripts["gentle-pi"] = true;

    fs.mkdirSync(path.dirname(packageJsonPath), { recursive: true });
    const temporary = `''${packageJsonPath}.nix-tmp-''${process.pid}`;
    fs.writeFileSync(temporary, `''${JSON.stringify(packageJson, null, 2)}\n`, { mode: 0o644 });
    fs.renameSync(temporary, packageJsonPath);
  '';

  patchAntigravitySecondAccount = writeText "patch-antigravity-second-account.mjs" ''
    import fs from "node:fs";
    import path from "node:path";

    const [packageRoot] = process.argv.slice(2);
    if (!packageRoot) throw new Error("missing cloned package root");

    function replace(relativePath, replacements) {
      const target = path.join(packageRoot, relativePath);
      let text = fs.readFileSync(target, "utf8");
      for (const [from, to, expected] of replacements) {
        const count = text.split(from).length - 1;
        if (expected !== undefined && count !== expected) {
          throw new Error(`upstream compatibility check failed for ''${relativePath}: expected ''${expected} occurrence(s) of ''${JSON.stringify(from)}, found ''${count}`);
        }
        text = text.replaceAll(from, to);
      }
      fs.writeFileSync(target, text);
    }

    const packagePath = path.join(packageRoot, "package.json");
    const packageJson = JSON.parse(fs.readFileSync(packagePath, "utf8"));
    if (packageJson.name !== "pi-antigravity" || typeof packageJson.version !== "string") {
      throw new Error("upstream compatibility check failed for package.json");
    }
    packageJson.name = "pi-antigravity-alt";
    packageJson.description = "Generated second-account alias of pi-antigravity";
    packageJson.loonAliasSource = {
      name: "pi-antigravity",
      version: packageJson.version,
      schema: ${toString antigravityAliasSchema},
    };
    fs.writeFileSync(packagePath, `''${JSON.stringify(packageJson, null, 2)}\n`);

    replace("src/models/models.ts", [
      ['export const PROVIDER_ID = "antigravity";', 'export const PROVIDER_ID = "antigravity-alt";', 1],
      ['export const PROVIDER_NAME = "Antigravity";', 'export const PROVIDER_NAME = "Antigravity (cuenta B)";', 1],
      ["(Antigravity)", "(Antigravity cuenta B)"],
    ]);
    replace("src/models/discovery.ts", [
      ['export const ANTIGRAVITY_PERSIST_KEY = "pi-antigravity";', 'export const ANTIGRAVITY_PERSIST_KEY = "pi-antigravity-alt";', 1],
      ['provider: "antigravity",', 'provider: "antigravity-alt",', 1],
    ]);
    replace("src/types/types.ts", [
      ['export const ANTIGRAVITY_API = "antigravity-api" as const;', 'export const ANTIGRAVITY_API = "antigravity-alt-api" as const;', 1],
    ]);
    replace("src/index.ts", [
      ['getApiKeyForProvider("antigravity")', 'getApiKeyForProvider("antigravity-alt")', 1],
      ['name: "generate_image",', 'name: "generate_image_alt",', 1],
      ['label: "Generate image",', 'label: "Generate image (cuenta B)",', 1],
      ["/login antigravity", "/login antigravity-alt"],
      ["/antigravity.", "/antigravity-alt."],
      ['registerCommand("antigravity.', 'registerCommand("antigravity-alt.'],
    ]);
    replace("src/usage/usage.ts", [
      ['getApiKeyForProvider("antigravity")', 'getApiKeyForProvider("antigravity-alt")', 1],
      ["/antigravity.models", "/antigravity-alt.models"],
    ]);
    for (const relativePath of ["src/auth/oauth.ts", "src/client/client.ts"]) {
      replace(relativePath, [["/login antigravity", "/login antigravity-alt"]]);
    }
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
    model: opencode-go/deepseek-v4-flash
    thinking: xhigh
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
  # bash supplies `sh` for the one explicitly approved npm lifecycle script.
  # gzip is required by gentle-pi's trusted `/usr/bin/tar -xzf` extractor.
  runtimeInputs = [ coreutils bash git gzip nodejs piLauncher gentleAiLauncher engramLauncher ];

  text = ''
    agent_dir="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    npm_node_modules="$agent_dir/npm/node_modules"
    state_path="$HOME/.gentle-ai/state.json"
    repo_dir="''${GENTLE_AI_NIXOS_REPO:-$HOME/.nixos}"
    npm_prefix="''${PI_NPM_PREFIX:-$HOME/.local/share/loon-pi/npm-prefix}"
    mutable_pi="$npm_prefix/bin/pi"
    backup_dir="$agent_dir/backups/nix-gentle-ai/$(date +%Y%m%d%H%M%S)"

    mkdir -p "$npm_node_modules" "$HOME/.gentle-ai" "$npm_prefix"

    # Give Pi a stable, unhashed local-package identity for the customized UI
    # while keeping its bytes owned by the flake.
    local_package_root="$HOME/.local/share/loon-pi-packages"
    better_ui_source="$local_package_root/better-claude-code-ui"
    mkdir -p "$local_package_root"
    if [ ! -L "$better_ui_source" ] || [ "$(readlink -f "$better_ui_source" || true)" != "${betterClaudeCodeUi}" ]; then
      if [ -e "$better_ui_source" ] || [ -L "$better_ui_source" ]; then
        mkdir -p "$backup_dir/local-packages"
        mv "$better_ui_source" "$backup_dir/local-packages/better-claude-code-ui"
      fi
      ln -s "${betterClaudeCodeUi}" "$better_ui_source"
    fi

    # Install Pi only when absent. Subsequent upgrades belong to `pi update`,
    # which now sees a normal, writable global npm installation.
    if [ ! -x "$mutable_pi" ]; then
      npm install --global --prefix "$npm_prefix" \
        --ignore-scripts --no-audit --no-fund --loglevel=error \
        @earendil-works/pi-coding-agent@latest >/dev/null
    fi

    # The previous migration placed Pi in the general npm prefix, whose bin
    # directory is in PATH. Preserve that package in the backup and leave the
    # stable Nix launcher as the single visible `pi` command.
    legacy_pi_prefix="$HOME/.npm-global"
    if [ "$npm_prefix" != "$legacy_pi_prefix" ]; then
      legacy_pi_bin="$legacy_pi_prefix/bin/pi"
      legacy_pi_package="$legacy_pi_prefix/lib/node_modules/@earendil-works/pi-coding-agent"
      if [ -e "$legacy_pi_bin" ] || [ -L "$legacy_pi_bin" ]; then
        mkdir -p "$backup_dir/legacy-pi/bin"
        mv "$legacy_pi_bin" "$backup_dir/legacy-pi/bin/pi"
      fi
      if [ -e "$legacy_pi_package" ] || [ -L "$legacy_pi_package" ]; then
        mkdir -p "$backup_dir/legacy-pi/lib/node_modules/@earendil-works"
        mv "$legacy_pi_package" "$backup_dir/legacy-pi/lib/node_modules/@earendil-works/pi-coding-agent"
      fi
    fi

    # Install Engram only when its mutable runtime is absent. Explicit updates
    # are handled by `engram update` and `gentle-stack-update`.
    engram version >/dev/null

    # One-time migration from the previous Nix closure. Only store links from
    # loon-gentle-pi-stack are retired; mutable packages are never replaced.
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
      destination="$npm_node_modules/$package_name"
      if [ -L "$destination" ]; then
        resolved="$(readlink -f "$destination" || true)"
        case "$resolved" in
          /nix/store/*-loon-gentle-pi-stack-*)
            mkdir -p "$(dirname "$backup_dir/store-links/$package_name")"
            mv "$destination" "$backup_dir/store-links/$package_name"
            ;;
        esac
      fi
    done

    link_skill() {
      skill_name="$1"
      source="${../pi/skills}/$skill_name"
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

    # Global extension managed by the flake. Keep a user-created regular file
    # recoverable, while updated Nix store links can be replaced in place.
    notifications_source="${piNotifications}"
    notifications_destination="$agent_dir/extensions/loon-notifications.ts"
    mkdir -p "$agent_dir/extensions"
    if [ -L "$notifications_destination" ]; then
      ln -sfn "$notifications_source" "$notifications_destination"
    elif [ -e "$notifications_destination" ]; then
      mkdir -p "$backup_dir/extensions"
      mv "$notifications_destination" "$backup_dir/extensions/loon-notifications.ts"
      ln -s "$notifications_source" "$notifications_destination"
    else
      ln -s "$notifications_source" "$notifications_destination"
    fi

    # Keep quota handling outside gentle-pi: this global Pi extension also
    # loads in Gentle Agents child processes and shares one reset deadline.
    fallback_source="${antigravityQuotaFallback}"
    fallback_destination="$agent_dir/extensions/loon-antigravity-quota-fallback.ts"
    if [ -L "$fallback_destination" ]; then
      ln -sfn "$fallback_source" "$fallback_destination"
    elif [ -e "$fallback_destination" ]; then
      mkdir -p "$backup_dir/extensions"
      mv "$fallback_destination" "$backup_dir/extensions/loon-antigravity-quota-fallback.ts"
      ln -s "$fallback_source" "$fallback_destination"
    else
      ln -s "$fallback_source" "$fallback_destination"
    fi

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

    # Retire only obsolete standalone companions. Pi is intentionally mutable
    # now, and the `gentle-ai` launcher resolves gentle-pi's verified binary.
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

    # npm's lifecycle-script allowlist lives beside Pi's mutable extension
    # project. Create it before the first extension install and preserve any
    # other approvals the user may have added.
    npm_project="$agent_dir/npm"
    node "${mergeNpmPolicy}" "$npm_project/package.json"

    # The settings now contain unversioned npm sources. Install any missing
    # package set in one transaction; later upgrades remain explicit.
    missing_packages=0
    for package_name in \
      pi-antigravity \
      gentle-pi \
      gentle-engram \
      @juicesharp/rpiv-ask-user-question \
      pi-web-access \
      pi-btw \
      pi-commandcode-provider \
      pi-mcp-adapter; do
      if [ ! -e "$npm_node_modules/$package_name" ]; then
        missing_packages=1
        break
      fi
    done
    if [ "$missing_packages" -eq 1 ]; then
      (
        cd "$HOME"
        "$mutable_pi" update --extensions --no-approve
      )
    fi

    # Generate a second, independently authenticated provider from the exact
    # installed pi-antigravity release. Only provider/API/persistence ids,
    # commands and the duplicate image-tool name are changed. A version change
    # is picked up by gentle-stack-update's post-update bootstrap pass.
    antigravity_official="$npm_node_modules/pi-antigravity"
    antigravity_alt="$local_package_root/pi-antigravity-alt"
    official_antigravity_identity="$(node -p 'require(process.argv[1]).version' "$antigravity_official/package.json"):${toString antigravityAliasSchema}"
    installed_alias_identity="$(node -e '
      try {
        const source = require(process.argv[1]).loonAliasSource;
        if (typeof source?.version === "string" && Number.isInteger(source?.schema)) {
          process.stdout.write(source.version + ":" + source.schema);
        }
      } catch {}
    ' "$antigravity_alt/package.json")"

    if [ "$installed_alias_identity" != "$official_antigravity_identity" ]; then
      antigravity_alt_tmp="$(mktemp -d "$local_package_root/.pi-antigravity-alt.XXXXXX")"
      cp -a "$antigravity_official/." "$antigravity_alt_tmp/"
      if node "${patchAntigravitySecondAccount}" "$antigravity_alt_tmp"; then
        # The copied package resolves its ordinary npm dependencies through
        # Pi's managed extension tree without copying another dependency set.
        ln -s "$npm_node_modules" "$antigravity_alt_tmp/node_modules"
        if [ -e "$antigravity_alt" ] || [ -L "$antigravity_alt" ]; then
          mkdir -p "$backup_dir/local-packages"
          mv "$antigravity_alt" "$backup_dir/local-packages/pi-antigravity-alt"
        fi
        mv "$antigravity_alt_tmp" "$antigravity_alt"
      else
        rm -rf "$antigravity_alt_tmp"
        echo "gentle-ai-bootstrap: pi-antigravity changed incompatibly; preserving the previous account-B clone" >&2
      fi
    fi

    # The first settings pass intentionally skipped this generated path on a
    # clean machine. Add it now that its official source is available.
    node "${mergeSettings}" "$settings_path" "${manifest}"

    gentle_pi_root="$npm_node_modules/gentle-pi"
    verify_gentle_ai_runtime() {
      node --input-type=module - "$gentle_pi_root" <<'NODE' >/dev/null 2>&1
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const packageRoot = process.argv[2];
const moduleUrl = pathToFileURL(join(packageRoot, "runtime", "gentle-ai-binary.mjs"));
const { resolveGentleAiBinary } = await import(moduleUrl.href);
resolveGentleAiBinary(packageRoot);
NODE
    }

    # Repair installations created before the npm policy existed. Future
    # gentle-pi upgrades run the same approved postinstall automatically.
    if ! verify_gentle_ai_runtime; then
      npm rebuild gentle-pi --prefix "$npm_project" --foreground-scripts
    fi
    if ! verify_gentle_ai_runtime; then
      echo "gentle-ai-bootstrap: gentle-pi's verified Gentle AI runtime is unavailable" >&2
      exit 1
    fi

    # This local UI fork is the deliberate declarative exception to mutable
    # extension updates. Its package path stays immutable and versioned here.
    better_ui="$npm_node_modules/better-claude-code-ui"
    if [ ! -L "$better_ui" ] || [ "$(readlink -f "$better_ui" || true)" != "${betterClaudeCodeUi}" ]; then
      if [ -e "$better_ui" ] || [ -L "$better_ui" ]; then
        mkdir -p "$backup_dir/packages"
        mv "$better_ui" "$backup_dir/packages/better-claude-code-ui"
      fi
      ln -s "${betterClaudeCodeUi}" "$better_ui"
    fi

    # Reconcile only Nix-managed providers and preserve any local providers.
    node "${mergeModels}" "$agent_dir/models.json" "${manifest}"

    if [ ! -d "$gentle_pi_root/assets" ]; then
      echo "gentle-ai-bootstrap: gentle-pi did not install correctly" >&2
      exit 1
    fi

    # Reconcile the mutable package's current assets with the declarative
    # model routes. A package update therefore needs no Nix source edit.
    mkdir -p "$agent_dir/agents" "$agent_dir/chains" "$agent_dir/gentle-ai/support"
    cp "$gentle_pi_root/assets/agents/"*.md "$agent_dir/agents/"
    cp "$gentle_pi_root/assets/chains/"*.md "$agent_dir/chains/"
    cp "$gentle_pi_root/assets/support/"*.md "$agent_dir/gentle-ai/support/"
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
    elif [ -L "$mcp_path" ]; then
      if [ "$(readlink -f "$mcp_path" || true)" = "${mcpConfig}" ]; then
        mcp_path=""
      else
        mkdir -p "$(dirname "$backup_dir/mcp.json")"
        mv "$mcp_path" "$backup_dir/mcp.json"
      fi
    fi
    if [ -n "$mcp_path" ]; then
      ln -s "${mcpConfig}" "$mcp_path"
    fi

    node "${mergeState}" "$state_path"

    # A fresh machine gets RDD enabled once. Respect any later explicit disable.
    if [ -d "$repo_dir/.git" ]; then
      if [ ! -f "$state_path" ] || node -e '
        const fs = require("node:fs");
        const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.exit(!Object.prototype.hasOwnProperty.call(state, "rdd_mode") || state.rdd_mode === "on" ? 0 : 1);
      ' "$state_path"; then
        gentle-ai review mode enable --scope global --cwd "$repo_dir" >/dev/null
      fi
    fi

    echo "Gentle AI y Pi quedaron inicializados en su instalación mutable administrada por el usuario."
  '';
}
