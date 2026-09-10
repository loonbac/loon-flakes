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

export const FALLBACK_PROVIDER = "opencode-go";
export const FALLBACK_MODEL = "muse-spark-1.3-contributor";

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

export default function antigravityQuotaFallback(pi: ExtensionAPI): void {
  let originalModel: ExtensionContext["model"];
  let fallbackActive = false;
  let retryQueued = false;
  let switchInProgress = false;

  const showState = (ctx: ExtensionContext, state = readState()): void => {
    ctx.ui.setStatus(
      STATUS_KEY,
      state ? `Antigravity → Muse Spark 1.3 (${remaining(state)})` : undefined,
    );
  };

  const activateFallback = async (ctx: ExtensionContext): Promise<boolean> => {
    if (fallbackActive || switchInProgress) return fallbackActive;
    const fallback = ctx.modelRegistry.find(FALLBACK_PROVIDER, FALLBACK_MODEL);
    if (!fallback) {
      ctx.ui.notify(
        `No se encontró ${FALLBACK_PROVIDER}/${FALLBACK_MODEL}; no se pudo activar el fallback.`,
        "error",
      );
      return false;
    }

    switchInProgress = true;
    try {
      if (ctx.model?.provider === "antigravity") originalModel = ctx.model;
      fallbackActive = await pi.setModel(fallback);
      if (!fallbackActive) {
        ctx.ui.notify(
          `La autenticación de ${FALLBACK_PROVIDER}/${FALLBACK_MODEL} no está disponible.`,
          "error",
        );
      }
      return fallbackActive;
    } finally {
      switchInProgress = false;
    }
  };

  pi.on("session_start", (_event, ctx) => {
    originalModel = undefined;
    fallbackActive = false;
    retryQueued = false;
    showState(ctx);
  });

  // Every Pi process, including Gentle Agents children, reads the shared
  // cooldown before its run. This prevents one failed subagent per route after
  // the first Antigravity quota error has established the reset deadline.
  pi.on("before_agent_start", async (_event, ctx) => {
    const state = readState();
    showState(ctx, state);
    if (state && ctx.model?.provider === "antigravity") {
      await activateFallback(ctx);
    }
  });

  // Pi persists provider failures as assistant messages. Switch the current
  // run and queue one continuation; the failed message remains as evidence but
  // is ignored by providers when the request is reconstructed.
  pi.on("message_end", async (event, ctx) => {
    const message = event.message;
    if (
      retryQueued ||
      message.role !== "assistant" ||
      message.provider !== "antigravity" ||
      message.stopReason !== "error" ||
      !isQuotaExhaustion(message.errorMessage)
    ) {
      return;
    }

    const state = writeState(message.errorMessage, message.model);
    showState(ctx, state);
    if (!(await activateFallback(ctx))) return;

    retryQueued = true;
    ctx.ui.notify(
      `Cuota de Antigravity agotada; continuando con ${FALLBACK_PROVIDER}/${FALLBACK_MODEL}.`,
      "warning",
    );
    pi.sendMessage(
      {
        customType: "antigravity-quota-fallback",
        content:
          "Antigravity agotó su cuota. Continúa automáticamente la petición pendiente con el modelo de respaldo; no pidas al usuario que la repita.",
        display: true,
        details: { fallbackProvider: FALLBACK_PROVIDER, fallbackModel: FALLBACK_MODEL },
      },
      { triggerTurn: true, deliverAs: "followUp" },
    );
  });

  // Model changes made by the fallback are scoped to one settled request. The
  // original route remains in the session and will be tried again once the
  // provider-reported cooldown has expired.
  pi.on("agent_settled", async (_event, ctx) => {
    if (
      fallbackActive &&
      originalModel &&
      ctx.model?.provider === FALLBACK_PROVIDER &&
      ctx.model.id === FALLBACK_MODEL
    ) {
      await pi.setModel(originalModel);
    }
    originalModel = undefined;
    fallbackActive = false;
    retryQueued = false;
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
        `Fallback activo durante ${remaining(state)} hacia ${FALLBACK_PROVIDER}/${FALLBACK_MODEL}.`,
        "info",
      );
    },
  });
}
