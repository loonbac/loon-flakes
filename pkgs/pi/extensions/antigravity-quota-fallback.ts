import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export const FALLBACK_CHAIN = [
  {
    provider: "explabs",
    model: "deepseek-v4.1-flash",
    label: "Experiential DeepSeek V4.1 Flash",
  },
  {
    provider: "opencode-go",
    model: "muse-spark-1.3-contributor",
    label: "Muse Spark 1.3",
  },
] as const;

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

export function fallbackIndex(provider: string, model: string): number {
  return FALLBACK_CHAIN.findIndex((route) => route.provider === provider && route.model === model);
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
  let originalModel: ExtensionContext["model"];
  let activeFallbackIndex: number | undefined;
  let queuedFallbackIndexes = new Set<number>();
  let switchInProgress = false;

  const showState = (ctx: ExtensionContext, state = readState()): void => {
    ctx.ui.setStatus(
      STATUS_KEY,
      state ? `Antigravity → DeepSeek V4.1 → Muse Spark 1.3 (${remaining(state)})` : undefined,
    );
  };

  const activateFallback = async (
    ctx: ExtensionContext,
    startIndex: number,
  ): Promise<number | undefined> => {
    if (switchInProgress) return activeFallbackIndex;
    switchInProgress = true;
    try {
      if (ctx.model?.provider === "antigravity") originalModel = ctx.model;

      for (let index = startIndex; index < FALLBACK_CHAIN.length; index += 1) {
        const route = FALLBACK_CHAIN[index];
        const fallback = ctx.modelRegistry.find(route.provider, route.model);
        if (!fallback) {
          ctx.ui.notify(
            `No se encontró ${route.provider}/${route.model}; probando el siguiente fallback.`,
            "warning",
          );
          continue;
        }
        if (await pi.setModel(fallback)) {
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
      const failedIndex = fallbackIndex(message.provider, message.model);
      if (
        failedIndex < 0 ||
        activeFallbackIndex !== failedIndex ||
        !originalModel ||
        failedIndex + 1 >= FALLBACK_CHAIN.length
      ) {
        return;
      }
      startIndex = failedIndex + 1;
      reason = `${FALLBACK_CHAIN[failedIndex].label} falló`;
    }

    const activatedIndex = await activateFallback(ctx, startIndex);
    if (activatedIndex === undefined || queuedFallbackIndexes.has(activatedIndex)) return;

    queuedFallbackIndexes.add(activatedIndex);
    const route = FALLBACK_CHAIN[activatedIndex];
    ctx.ui.notify(
      `${reason}; continuando con ${route.provider}/${route.model}.`,
      "warning",
    );
    if (isRetryableAssistantError(message)) return;

    pi.sendMessage(
      {
        customType: "antigravity-quota-fallback",
        content:
          `${reason}. Continúa automáticamente la petición pendiente con ${route.label}; no pidas al usuario que la repita.`,
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
      ? fallbackIndex(ctx.model.provider, ctx.model.id)
      : -1;
    if (
      activeFallbackIndex !== undefined &&
      originalModel &&
      currentFallbackIndex === activeFallbackIndex
    ) {
      await pi.setModel(originalModel);
    }
    originalModel = undefined;
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
        `Fallback activo durante ${remaining(state)}: DeepSeek V4.1 Flash y luego Muse Spark 1.3.`,
        "info",
      );
    },
  });
}
