import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export type FallbackThinking = "high" | "xhigh" | "max";

export interface FallbackRoute {
  provider: string;
  model: string;
  label: string;
  thinking?: FallbackThinking;
}

const DEEPSEEK_HIGH: FallbackRoute = {
  provider: "explabs",
  model: "deepseek-v4.1-flash",
  label: "DeepSeek V4.1 Flash",
  thinking: "high",
};

const MUSE_XHIGH: FallbackRoute = {
  provider: "opencode-go",
  model: "muse-spark-1.3-contributor",
  label: "Muse Spark 1.3",
  thinking: "xhigh",
};

const MUSE_MAX: FallbackRoute = {
  provider: "opencode-go",
  model: "muse-spark-1.3-contributor",
  label: "Muse Spark 1.3",
  // This expresses the requested policy. Pi clamps it to xhigh because the
  // current free Contributor catalogue publishes max: null for this model.
  thinking: "max",
};

// Unknown agents and ordinary Pi sessions retain the existing global order
// and their current thinking level. The named Gentle agents below receive the
// two explicit routes requested for their workload.
export const FALLBACK_CHAIN: readonly FallbackRoute[] = [
  {
    provider: "explabs",
    model: "deepseek-v4.1-flash",
    label: "DeepSeek V4.1 Flash",
  },
  {
    provider: "opencode-go",
    model: "muse-spark-1.3-contributor",
    label: "Muse Spark 1.3",
  },
] as const;

export const AGENT_FALLBACK_CHAINS: Readonly<Record<string, readonly FallbackRoute[]>> = {
  "gentle-ai-explore": [DEEPSEEK_HIGH, MUSE_XHIGH],
  "gentle-ai-worker": [MUSE_MAX, DEEPSEEK_HIGH],
  "jd-fix-agent": [DEEPSEEK_HIGH, MUSE_MAX],
  "sdd-explore": [DEEPSEEK_HIGH, MUSE_XHIGH],
  "sdd-spec": [MUSE_XHIGH, DEEPSEEK_HIGH],
  "sdd-tasks": [DEEPSEEK_HIGH, MUSE_XHIGH],
  "sdd-apply": [MUSE_MAX, DEEPSEEK_HIGH],
  "sdd-onboard": [DEEPSEEK_HIGH, MUSE_XHIGH],
};

const STATE_VERSION = 1;
const DEFAULT_COOLDOWN_MS = 24 * 60 * 60 * 1000;
const RESET_BUFFER_MS = 2 * 60 * 1000;
const STATUS_KEY = "antigravity-quota-fallback";
const QUOTA_ERROR = /(?:quota\s+(?:reached|exceeded|exhausted)|resource[_\s-]?exhausted|usage\s+(?:limit|quota)[^\n]*(?:reached|exceeded|exhausted)|(?:daily|monthly)\s+(?:usage\s+)?limit[^\n]*(?:reached|exceeded|exhausted))/i;

interface CooldownState {
  version: number;
  activeUntil: number;
  detectedAt: number;
  sourceModel: string;
}

export function isQuotaExhaustion(errorMessage: unknown): errorMessage is string {
  return typeof errorMessage === "string" && QUOTA_ERROR.test(errorMessage);
}

export function parseWaitDurationMs(errorMessage: string): number | undefined {
  const wait = errorMessage.match(/(?:please\s+wait|retry\s+(?:in|after))\s+((?:\d+\s*[dhms]\s*)+)/i)?.[1];
  if (!wait) return undefined;

  let total = 0;
  for (const match of wait.matchAll(/(\d+)\s*([dhms])/gi)) {
    const value = Number.parseInt(match[1], 10);
    const unit = match[2].toLowerCase();
    if (unit === "d") total += value * 24 * 60 * 60 * 1000;
    if (unit === "h") total += value * 60 * 60 * 1000;
    if (unit === "m") total += value * 60 * 1000;
    if (unit === "s") total += value * 1000;
  }
  return total > 0 ? total : undefined;
}

export function cooldownDeadline(errorMessage: string, now = Date.now()): number {
  return now + (parseWaitDurationMs(errorMessage) ?? DEFAULT_COOLDOWN_MS) + RESET_BUFFER_MS;
}

export function fallbackChainForAgent(agentName: string | undefined): readonly FallbackRoute[] {
  return (agentName && AGENT_FALLBACK_CHAINS[agentName]) || FALLBACK_CHAIN;
}

export function fallbackIndex(
  provider: string,
  model: string,
  chain: readonly FallbackRoute[] = FALLBACK_CHAIN,
): number {
  return chain.findIndex((route) => route.provider === provider && route.model === model);
}

interface AgentDefinitionIdentity {
  name: string;
  instructions: string;
}

export function parseAgentDefinitionIdentity(
  text: string,
  fallbackName: string,
): AgentDefinitionIdentity | undefined {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
  if (!match) return undefined;
  const declaredName = match[1].match(/^name:\s*["']?([^\r\n"']+)["']?\s*$/m)?.[1]?.trim();
  const instructions = match[2].trim();
  if (!instructions) return undefined;
  return { name: declaredName || fallbackName, instructions };
}

export function appendedSystemPrompts(argv: readonly string[]): string[] {
  const prompts: string[] = [];
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--append-system-prompt" && index + 1 < argv.length) {
      prompts.push(argv[index + 1]);
      index += 1;
    } else if (argument.startsWith("--append-system-prompt=")) {
      prompts.push(argument.slice("--append-system-prompt=".length));
    }
  }
  return prompts;
}

export function matchGentleAgentName(
  prompts: readonly string[],
  definitions: Iterable<AgentDefinitionIdentity>,
): string | undefined {
  const available = [...definitions];
  for (const prompt of [...prompts].reverse()) {
    const normalized = prompt.trim();
    const match = available.find((definition) => definition.instructions === normalized);
    if (match) return match.name;
  }
  return undefined;
}

function gentleAgentHome(environment: NodeJS.ProcessEnv): string {
  return environment.GENTLE_PI_AGENT_HOME
    || environment.PI_CODING_AGENT_DIR
    || join(homedir(), ".pi", "agent");
}

export function detectGentleAgentName(
  argv: readonly string[] = process.argv,
  environment: NodeJS.ProcessEnv = process.env,
  cwd = process.cwd(),
): string | undefined {
  if (environment.GENTLE_PI_AGENTS_CHILD !== "1") return undefined;
  const prompts = appendedSystemPrompts(argv);
  if (prompts.length === 0) return undefined;

  const definitions = new Map<string, AgentDefinitionIdentity>();
  const agentHome = gentleAgentHome(environment);
  for (const directory of [
    join(agentHome, "agents"),
    join(agentHome, "subagents"),
    join(cwd, ".pi", "agents"),
    join(cwd, ".pi", "subagents"),
  ]) {
    if (!existsSync(directory)) continue;
    for (const fileName of readdirSync(directory).filter((name) => name.endsWith(".md")).sort()) {
      const identity = parseAgentDefinitionIdentity(
        readFileSync(join(directory, fileName), "utf8"),
        fileName.replace(/\.md$/i, ""),
      );
      if (identity) definitions.set(identity.name, identity);
    }
  }

  return matchGentleAgentName(prompts, definitions.values());
}

function statePath(): string {
  const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
  return join(agentDir, "state", "antigravity-quota-fallback.json");
}

function readState(now = Date.now()): CooldownState | undefined {
  const path = statePath();
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<CooldownState>;
    if (
      parsed.version !== STATE_VERSION ||
      typeof parsed.activeUntil !== "number" ||
      !Number.isFinite(parsed.activeUntil) ||
      parsed.activeUntil <= now
    ) {
      return undefined;
    }
    return parsed as CooldownState;
  } catch {
    return undefined;
  }
}

function writeState(errorMessage: string, sourceModel: string, now = Date.now()): CooldownState {
  const path = statePath();
  const current = readState(now);
  const state: CooldownState = {
    version: STATE_VERSION,
    activeUntil: Math.max(current?.activeUntil ?? 0, cooldownDeadline(errorMessage, now)),
    detectedAt: now,
    sourceModel,
  };
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, path);
  chmodSync(path, 0o600);
  return state;
}

function clearState(): void {
  rmSync(statePath(), { force: true });
}

function remaining(state: CooldownState): string {
  const totalMinutes = Math.max(1, Math.ceil((state.activeUntil - Date.now()) / 60000));
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
}

export default async function antigravityQuotaFallback(pi: ExtensionAPI): Promise<void> {
  // Use Pi's own transient-error classifier so the extension does not enqueue
  // a second turn when Pi is already going to retry the failed request.
  const { isRetryableAssistantError } = await import("@earendil-works/pi-ai");
  const gentleAgentName = detectGentleAgentName();
  const fallbackChain = fallbackChainForAgent(gentleAgentName);
  let originalModel: ExtensionContext["model"];
  let originalThinkingLevel: ReturnType<ExtensionAPI["getThinkingLevel"]> | undefined;
  let activeFallbackIndex: number | undefined;
  let queuedFallbackIndexes = new Set<number>();
  let switchInProgress = false;

  const routeLabel = (route: FallbackRoute): string =>
    `${route.label}${route.thinking ? ` ${route.thinking}` : ""}`;

  const chainLabel = (): string => fallbackChain.map(routeLabel).join(" → ");

  const showState = (ctx: ExtensionContext, state = readState()): void => {
    ctx.ui.setStatus(
      STATUS_KEY,
      state ? `Antigravity → ${chainLabel()} (${remaining(state)})` : undefined,
    );
  };

  const activateFallback = async (
    ctx: ExtensionContext,
    startIndex: number,
  ): Promise<number | undefined> => {
    if (switchInProgress) return activeFallbackIndex;
    switchInProgress = true;
    try {
      if (ctx.model?.provider === "antigravity" && !originalModel) {
        originalModel = ctx.model;
        originalThinkingLevel = pi.getThinkingLevel();
      }

      for (let index = startIndex; index < fallbackChain.length; index += 1) {
        const route = fallbackChain[index];
        const fallback = ctx.modelRegistry.find(route.provider, route.model);
        if (!fallback) {
          ctx.ui.notify(
            `No se encontró ${route.provider}/${route.model}; probando el siguiente fallback.`,
            "warning",
          );
          continue;
        }
        if (await pi.setModel(fallback)) {
          if (route.thinking) pi.setThinkingLevel(route.thinking);
          activeFallbackIndex = index;
          return index;
        }
        ctx.ui.notify(
          `La autenticación de ${route.provider}/${route.model} no está disponible; probando el siguiente fallback.`,
          "warning",
        );
      }

      ctx.ui.notify("No queda ningún modelo disponible en la cadena de fallback.", "error");
      return undefined;
    } finally {
      switchInProgress = false;
    }
  };

  pi.on("session_start", (_event, ctx) => {
    originalModel = undefined;
    originalThinkingLevel = undefined;
    activeFallbackIndex = undefined;
    queuedFallbackIndexes = new Set<number>();
    showState(ctx);
  });

  // Every Pi process, including Gentle Agents children, reads the shared
  // cooldown before its run. This prevents one failed subagent per route after
  // the first Antigravity quota error has established the reset deadline.
  pi.on("before_agent_start", async (_event, ctx) => {
    const state = readState();
    showState(ctx, state);
    if (state && ctx.model?.provider === "antigravity") {
      await activateFallback(ctx, 0);
    }
  });

  // Pi persists provider failures as assistant messages. Switch the current
  // run and continue it exactly once: transient errors use Pi's built-in retry,
  // while quota errors need an explicit follow-up. The failed message remains
  // as evidence but is ignored when the provider request is reconstructed.
  pi.on("message_end", async (event, ctx) => {
    const message = event.message;
    if (message.role !== "assistant" || message.stopReason !== "error") return;

    let startIndex: number;
    let reason: string;
    if (message.provider === "antigravity" && isQuotaExhaustion(message.errorMessage)) {
      const state = writeState(message.errorMessage, message.model);
      showState(ctx, state);
      startIndex = 0;
      reason = "Antigravity agotó su cuota";
    } else {
      const failedIndex = fallbackIndex(message.provider, message.model, fallbackChain);
      if (
        failedIndex < 0 ||
        activeFallbackIndex !== failedIndex ||
        !originalModel ||
        failedIndex + 1 >= fallbackChain.length
      ) {
        return;
      }
      startIndex = failedIndex + 1;
      reason = `${routeLabel(fallbackChain[failedIndex])} falló`;
    }

    const activatedIndex = await activateFallback(ctx, startIndex);
    if (activatedIndex === undefined || queuedFallbackIndexes.has(activatedIndex)) return;

    queuedFallbackIndexes.add(activatedIndex);
    const route = fallbackChain[activatedIndex];
    ctx.ui.notify(
      `${reason}; continuando con ${route.provider}/${route.model}.`,
      "warning",
    );
    if (isRetryableAssistantError(message)) return;

    pi.sendMessage(
      {
        customType: "antigravity-quota-fallback",
        content:
          `${reason}. Continúa automáticamente la petición pendiente con ${routeLabel(route)}; no pidas al usuario que la repita.`,
        display: true,
        details: {
          fallbackProvider: route.provider,
          fallbackModel: route.model,
          fallbackIndex: activatedIndex,
        },
      },
      { triggerTurn: true, deliverAs: "followUp" },
    );
  });

  // Model changes made by the fallback are scoped to one settled request. The
  // original route remains in the session and will be tried again once the
  // provider-reported cooldown has expired.
  pi.on("agent_settled", async (_event, ctx) => {
    const currentFallbackIndex = ctx.model
      ? fallbackIndex(ctx.model.provider, ctx.model.id, fallbackChain)
      : -1;
    if (
      activeFallbackIndex !== undefined &&
      originalModel &&
      currentFallbackIndex === activeFallbackIndex
    ) {
      await pi.setModel(originalModel);
      if (originalThinkingLevel) pi.setThinkingLevel(originalThinkingLevel);
    }
    originalModel = undefined;
    originalThinkingLevel = undefined;
    activeFallbackIndex = undefined;
    queuedFallbackIndexes = new Set<number>();
    showState(ctx);
  });

  pi.registerCommand("antigravity-fallback", {
    description: "Muestra o limpia el fallback automático de cuota de Antigravity",
    handler: async (args, ctx) => {
      if (args.trim() === "clear") {
        clearState();
        showState(ctx, undefined);
        ctx.ui.notify("Fallback de Antigravity limpiado; el próximo uso probará el modelo original.", "info");
        return;
      }
      const state = readState();
      if (!state) {
        ctx.ui.notify("Fallback inactivo; Antigravity se usará normalmente.", "info");
        return;
      }
      ctx.ui.notify(
        `Fallback activo durante ${remaining(state)}${gentleAgentName ? ` para ${gentleAgentName}` : ""}: ${chainLabel()}.`,
        "info",
      );
    },
  });
}
