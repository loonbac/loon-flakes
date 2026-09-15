import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const SUPPORTED_MODELS = new Set([
  "openai/gpt-5.4", "openai/gpt-5.4-mini", "openai/gpt-5.5", "openai/gpt-5.6",
  "openai/gpt-5.6-sol", "openai/gpt-5.6-terra", "openai/gpt-5.6-luna",
  "openai-codex/gpt-5.4", "openai-codex/gpt-5.4-mini", "openai-codex/gpt-5.5",
  "openai-codex/gpt-5.6", "openai-codex/gpt-5.6-sol", "openai-codex/gpt-5.6-terra",
  "openai-codex/gpt-5.6-luna",
]);

type Model = { provider?: string; id?: string };
type Context = { model?: Model; ui?: { notify?: (message: string, level?: string) => void } };

function agentDirectory(): string {
  return process.env.PI_CODING_AGENT_DIR?.trim() || join(process.env.HOME || "/home/loonbac", ".pi", "agent");
}

function statePath(): string {
  return join(agentDirectory(), "state", "pi-gpt-fast-mode.json");
}

function defaultEnabled(): boolean {
  try {
    const settings = JSON.parse(readFileSync(join(agentDirectory(), "settings.json"), "utf8")) as Record<string, unknown>;
    const config = settings["pi-gpt-fast-mode"];
    return typeof config === "object" && config !== null && (config as { enabled?: unknown }).enabled === true;
  } catch {
    return false;
  }
}

function loadEnabled(): boolean {
  try {
    const state = JSON.parse(readFileSync(statePath(), "utf8")) as { enabled?: unknown };
    return typeof state.enabled === "boolean" ? state.enabled : defaultEnabled();
  } catch {
    return defaultEnabled();
  }
}

function saveEnabled(enabled: boolean): void {
  const path = statePath();
  const temporary = `${path}.${process.pid}.tmp`;
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(temporary, `${JSON.stringify({ enabled })}\n`, { mode: 0o600 });
  renameSync(temporary, path);
}

function supported(model: Model | undefined): boolean {
  return Boolean(model?.provider && model.id && SUPPORTED_MODELS.has(`${model.provider}/${model.id}`));
}

export default function sharedFastMode(pi: ExtensionAPI): void {
  let enabled = loadEnabled();

  const toggle = (ctx: Context): void => {
    enabled = !enabled;
    saveEnabled(enabled);
    const model = ctx.model?.provider && ctx.model.id ? `${ctx.model.provider}/${ctx.model.id}` : "unknown model";
    ctx.ui?.notify?.(
      enabled
        ? supported(ctx.model)
          ? "GPT Fast mode enabled for this session and future subagents."
          : `GPT Fast mode enabled for future supported subagents; ${model} is not supported.`
        : "GPT Fast mode disabled for this session and future subagents.",
      enabled && !supported(ctx.model) ? "warning" : "info",
    );
  };

  pi.registerCommand("fast", {
    description: "Toggle shared GPT Fast mode (service_tier: priority)",
    handler: async (_args, ctx: Context) => {
      toggle(ctx);
    },
  });

  pi.registerShortcut("ctrl+alt+m", {
    description: "Toggle shared GPT Fast mode",
    handler: async (ctx: Context) => toggle(ctx),
  });

  pi.on("session_start", () => {
    enabled = loadEnabled();
  });

  pi.on("before_provider_request", (event, ctx: Context) => {
    if (!enabled || !supported(ctx.model) || event.payload?.model !== ctx.model?.id) return undefined;
    return { ...event.payload, service_tier: "priority" };
  });
}
