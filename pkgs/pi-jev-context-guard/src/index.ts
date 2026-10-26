import { appendFile, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
  SessionBeforeCompactEvent,
  SessionBeforeCompactResult,
} from "@earendil-works/pi-coding-agent";

const TYPESAFE_URL = "https://api.typesafe.ai/v1/systemone";
const JEV_MODEL = "jev-latest";

export interface Question {
  type: "noul" | "choice" | "score";
  instructions: string;
  criteria?: Record<string, unknown>;
}

export interface Answers {
  [id: string]:
    | { type: "noul"; noul: number }
    | { type: "choice"; choice: string; probabilities: Record<string, number>; confidence: number }
    | { type: "score"; score: number; legend: Record<string, string>; probabilities: Record<string, number>; confidence: number };
}

export interface AskResponse {
  model: string;
  answers: Answers;
  usage: { input_tokens: number; output_tokens: number };
}

export async function askJev(
  apiKey: string,
  state: unknown,
  questions: Record<string, Question>,
  signal: AbortSignal | undefined,
  timeoutMs: number,
): Promise<AskResponse> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const forward = () => controller.abort();
  signal?.addEventListener("abort", forward, { once: true });
  try {
    const res = await fetch(TYPESAFE_URL, {
      method: "POST",
      headers: {
        authorization: "Bearer " + apiKey,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({ state, model: JEV_MODEL, questions }),
      redirect: "manual",
      signal: controller.signal,
    });
    if (!res.ok) throw new Error("Jev HTTP " + res.status);
    const body = (await res.json()) as AskResponse;
    if (!body || typeof body !== "object" || !body.answers) throw new Error("Jev malformed response");
    return body;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", forward);
  }
}

async function readTypeSafeKey(agentDir: string): Promise<string | undefined> {
  try {
    const raw = await readFile(join(agentDir, "typesafe", "config.json"), "utf8");
    const parsed = JSON.parse(raw) as { apiKey?: unknown };
    return typeof parsed.apiKey === "string" && parsed.apiKey.trim().length > 0 ? parsed.apiKey : undefined;
  } catch {
    return undefined;
  }
}

export interface GuardState {
  context: { tokens: number | null; window: number; percent: number | null };
  model: string;
  session: { entries: number; lastCompaction: string | null };
  recentMessages: { role: string; text: string }[];
  currentInput: string;
}

export function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((c: { type?: string; text?: string }) =>
        c && typeof c === "object" && c.type === "text" && typeof c.text === "string" ? c.text : "",
      )
      .filter((s: string) => s.length > 0)
      .join(" ");
  }
  return "";
}

export function recentMessagesFrom(entries: unknown[], limit: number): { role: string; text: string }[] {
  const messages: { role: string; text: string }[] = [];
  for (const entry of entries) {
    const e = entry as { type?: string; message?: { role?: string; content?: unknown } };
    if (e.type === "message" && e.message && (e.message.role === "user" || e.message.role === "assistant")) {
      const text = extractText(e.message.content).trim();
      if (text.length > 0) messages.push({ role: e.message.role ?? "unknown", text: text.slice(0, 400) });
    }
  }
  return messages.slice(-limit);
}

export function buildState(event: { text: string }, ctx: ExtensionContext): GuardState | undefined {
  let entries: unknown[] = [];
  try {
    entries = ctx.sessionManager.getEntries() as unknown[];
  } catch {
    return undefined;
  }
  let lastCompaction: string | null = null;
  for (const entry of entries) {
    const e = entry as { type?: string; summary?: string };
    if (e.type === "compaction") lastCompaction = e.summary ? e.summary.slice(0, 120) : "(summary unavailable)";
  }
  const usage = (() => {
    try { return ctx.getContextUsage(); } catch { return null; }
  })();
  return {
    context: {
      tokens: usage ? usage.tokens : null,
      window: usage ? usage.contextWindow : 0,
      percent: usage ? usage.percent : null,
    },
    model: ctx.model ? ctx.model.provider + "/" + ctx.model.id : "unknown",
    session: { entries: entries.length, lastCompaction },
    recentMessages: recentMessagesFrom(entries, 12),
    currentInput: event.text.slice(0, 600),
  };
}

export const QUESTIONS: Record<string, Question> = {
  mid_task: {
    type: "noul",
    instructions:
      "Is the assistant MID-TASK on the work described in currentInput? " +
      "True means: the request continues or corrects work already in flight (unfinished edits, a failing test run, a partial implementation, an open question about ongoing changes) - summarizing now would lose live state. " +
      "False means: a settled topic is being closed, or the work in currentInput starts fresh and does not depend on mid-flight state in recentMessages.",
    criteria: {
      true: "Mid-task: the input continues/corrects unfinished work in flight; summarizing now would lose live state.",
      false: "Settled or fresh: the input closes a topic or starts work that does not depend on mid-flight state.",
    },
  },
  worth_memory: {
    type: "noul",
    instructions:
      "Given recentMessages and currentInput, is there a durable lesson, decision, or non-obvious discovery that should be saved to persistent memory (Engram) and would be useful in a FUTURE session? " +
      "True: a bug fix with a root cause, an architecture decision with a reason, a non-obvious codebase discovery, a config change, a user preference. " +
      "False: ordinary Q&A, transient progress, already-documented facts, or anything only useful in this session.",
    criteria: {
      true: "A durable lesson/decision/discovery worth persisting across sessions.",
      false: "Ordinary Q&A or transient state; nothing a future session would need.",
    },
  },
  heavy_context: {
    type: "choice",
    instructions:
      "Given context (current token usage vs window) and recentMessages, how pressing is compaction RIGHT NOW?",
    criteria: {
      "compact-now": "Context is heavy (>=85% of window) and the recent work looks settled enough to summarize.",
      soon: "Context is filling up (60-85%) or will be heavy within a few more exchanges; compaction is needed soon but is not urgent.",
      "keep-going": "Context is comfortable (<60%) or the work is mid-flight and compacting now would lose live state.",
      other: "Not enough information to judge.",
    },
  },
  session_fresh: {
    type: "choice",
    instructions:
      "If compaction happens, would this session be BETTER OFF starting fresh? Base it on recentMessages: how much of the recent context is stale or unrelated to currentInput, and how much live state would a summary lose?",
    criteria: {
      "new-session": "Most recent context is stale/unrelated to the current work; a fresh session with a summary is cleaner than continuing.",
      continue: "Recent context is still relevant to the current work; continuing (with compaction) preserves useful state.",
      other: "Not enough information to judge.",
    },
  },
};

export interface Decisions {
  compactionUrgency: string;
  saveToEngram: boolean;
  saveReason: string;
  sessionAdvice: string;
  taskState: string;
}

export function decide(answers: Answers): Decisions {
  const mid = answers.mid_task;
  const mem = answers.worth_memory;
  const heavy = answers.heavy_context;
  const fresh = answers.session_fresh;

  const midTask = mid && mid.type === "noul" ? mid.noul >= 0.5 : false;
  const memWorth = mem && mem.type === "noul" ? mem.noul >= 0.6 : false;
  const urgency = heavy && heavy.type === "choice" ? heavy.choice : "unknown";
  const session = fresh && fresh.type === "choice" ? fresh.choice : "unknown";

  const saveReason = !memWorth
    ? ""
    : midTask
      ? "Work is mid-flight and likely carries a durable lesson."
      : "A durable lesson/decision looks present in the recent exchange.";

  return {
    compactionUrgency: urgency,
    saveToEngram: memWorth,
    saveReason,
    sessionAdvice: session,
    taskState: midTask ? "mid-task" : "settled",
  };
}

export function buildCompactionInstructions(d: Decisions): string {
  const parts: string[] = [];
  if (d.taskState === "mid-task") {
    parts.push(
      "The task is mid-flight: preserve live state - files being edited, failing tests, open questions, partial implementations, and the next concrete step."
    );
  }
  if (d.sessionAdvice === "new-session") {
    parts.push(
      "The user will start a fresh session: end the summary with a clear handoff block that a new session can pick up without reading the full transcript."
    );
  }
  return parts.join(" ");
}

export async function trace(entry: Record<string, unknown>): Promise<void> {
  const file = process.env.PI_JEV_GUARD_LOG || join(homedir(), ".pi", "agent", "jev-guard.log");
  const line = JSON.stringify({ at: new Date().toISOString(), ...entry }) + "\n";
  await appendFile(file, line, { mode: 0o600 }).catch(() => {});
}

export default function jevContextGuard(pi: ExtensionAPI): void {
  if (process.env.PI_JEV_GUARD === "0") return;

  let apiKey: string | undefined;
  let lastAdvice = { at: 0, session: "" };
  let lastAutoCompact = 0;

  const agentDir = join(homedir(), ".pi", "agent");

  const getKey = async (): Promise<string | undefined> => {
    if (apiKey) return apiKey;
    apiKey = await readTypeSafeKey(agentDir);
    return apiKey;
  };

  const notify = (ctx: ExtensionContext, message: string, type: "info" | "warning" | "error"): void => {
    try { ctx.ui.notify(message, type); } catch { /* best-effort */ }
  };

  const AUTO_COMPACT_COOLDOWN_MS = 5 * 60 * 1000;

  // Every user message: one batched Jev request.
  pi.on("input", async (event: { text: string; streamingBehavior?: string }, ctx: ExtensionContext) => {
    if (event.streamingBehavior) return { action: "continue" as const };
    const key = await getKey();
    if (!key) return { action: "continue" as const };
    const state = buildState(event, ctx);
    if (!state) return { action: "continue" as const };

    const now = Date.now();
    if (now - lastAdvice.at < 10_000) return { action: "continue" as const };

    try {
      const timeoutMs = Number(process.env.PI_JEV_GUARD_TIMEOUT_MS || "4000");
      const response = await askJev(key, state, QUESTIONS, ctx.signal, timeoutMs);
      const d = decide(response.answers);
      lastAdvice = { at: now, session: d.sessionAdvice };

      await trace({
        event: "input_judged",
        tokens: state.context.tokens,
        percent: state.context.percent,
        task: d.taskState,
        compaction: d.compactionUrgency,
        session: d.sessionAdvice,
        saveToEngram: d.saveToEngram,
        usage: response.usage,
      });

      // Auto-compact when Jev says it is due and we are not mid-task.
      if (d.compactionUrgency === "compact-now" && d.taskState === "settled") {
        if (now - lastAutoCompact > AUTO_COMPACT_COOLDOWN_MS) {
          lastAutoCompact = now;
          const instructions = buildCompactionInstructions(d);
          ctx.compact({
            customInstructions: instructions || undefined,
            onComplete: () => trace({ event: "auto_compacted", reason: "jev_compact_now" }),
            onError: (err) => trace({ event: "auto_compact_error", error: err.message.slice(0, 200) }),
          });
          notify(ctx, "Jev: context is heavy and the task is settled - compacting now.", "info");
        } else {
          notify(ctx, "Jev: compact-now (cooldown active) - manual /compact is available.", "info");
        }
      } else if (d.compactionUrgency === "compact-now" && d.taskState === "mid-task") {
        notify(ctx, "Jev: context is heavy but the task is mid-flight - waiting for a settled moment.", "info");
      }

      if (d.saveToEngram) {
        notify(ctx, "Jev: this looks worth saving to Engram - " + d.saveReason, "info");
      }
      if (d.sessionAdvice === "new-session" && d.compactionUrgency === "compact-now") {
        notify(ctx, "Jev: a fresh session may be cleaner than continuing compacted. Your call.", "info");
      }
    } catch (error) {
      await trace({ event: "input_error", error: String(error instanceof Error ? error.message : error).slice(0, 200) });
    }

    return { action: "continue" as const };
  });

  // Compaction veto: only cancel when Jev says mid-task AND we just compacted (threshold < 50k).
  // Otherwise: allow the compaction but pass customInstructions so the summary preserves mid-flight state.
  pi.on("session_before_compact", async (event: SessionBeforeCompactEvent, ctx: ExtensionContext): Promise<SessionBeforeCompactResult> => {
    const key = await getKey();
    if (!key) return {};

    const state = (() => {
      try {
        const entries = ctx.sessionManager.getEntries() as unknown[];
        return {
          context: { tokens: event.preparation.tokensBefore, window: 0, percent: null },
          trigger: event.reason,
          isSplitTurn: event.preparation.isSplitTurn,
          messagesToSummarize: event.preparation.messagesToSummarize.length,
          recentMessages: recentMessagesFrom(entries, 12),
          currentInput: "",
        };
      } catch {
        return undefined;
      }
    })();
    if (!state) return {};

    try {
      const timeoutMs = Number(process.env.PI_JEV_GUARD_TIMEOUT_MS || "4000");
      const response = await askJev(
        key,
        state,
        { mid_task: QUESTIONS.mid_task, session_fresh: QUESTIONS.session_fresh },
        event.signal,
        timeoutMs,
      );
      const d = decide({ ...response.answers, worth_memory: { type: "noul", noul: 0 }, heavy_context: { type: "choice", choice: "keep-going", probabilities: {}, confidence: 0 } });

      await trace({
        event: "before_compact",
        trigger: event.reason,
        tokensBefore: event.preparation.tokensBefore,
        task: d.taskState,
        session: d.sessionAdvice,
        willRetry: event.willRetry,
        usage: response.usage,
      });

      // Only veto when: threshold trigger AND mid-task AND we just compacted (<50k tokens).
      // This prevents compacting twice in a row but does not block the normal auto-compaction flow.
      if (d.taskState === "mid-task" && event.reason === "threshold" && event.preparation.tokensBefore < 50_000 && !event.willRetry) {
        notify(ctx, "Jev: vetoing threshold compaction - just compacted and still mid-task.", "warning");
        return { cancel: true };
      }

      // For manual or overflow compaction: allow it. For threshold: also allow it (the veto
      // above is the only blocker). The auto-compact from the input hook already passes
      // customInstructions via ctx.compact({customInstructions}); the threshold auto-compaction
      // from pi uses the default summary, which is acceptable.
    } catch (error) {
      await trace({ event: "before_compact_error", error: String(error instanceof Error ? error.message : error).slice(0, 200) });
    }

    return {};
  });

  // After a real compaction: surface the session advice.
  pi.on("session_compact", async (event: { reason: string }, ctx: ExtensionContext) => {
    if (lastAdvice.session === "new-session") {
      notify(ctx, "Jev: after that compaction, a fresh session may be cleaner. Your call.", "info");
    }
    await trace({ event: "compacted", reason: event.reason, sessionAdvice: lastAdvice.session });
  });
}
