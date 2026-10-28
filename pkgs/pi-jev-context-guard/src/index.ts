import { appendFile, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  AgentEndEvent,
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
  const closed = () => controller.signal.aborted;
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
  context: { tokens: number | null; window: number; percent: number | null; messages?: number };
  model: string;
  session: {
    entries: number;
    messages: number;
    lastCompaction: string | null;
    // Mensajes posteriores a la última compactación de la sesión. Es la única
    // señal durable de "acabo de compactar": sobrevive al reinicio de Pi,
    // mientras que el cooldown en memoria no.
    sinceCompaction: number | null;
  };
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

export function latestAssistantText(messages: unknown[] | undefined, entries: unknown[]): string {
  if (Array.isArray(messages) && messages.length > 0) {
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i] as { role?: string; content?: unknown };
      if (m && m.role === "assistant") {
        const text = extractText(m.content).trim();
        if (text.length > 0) return text;
      }
    }
    const last = messages[messages.length - 1] as { content?: unknown };
    const text = extractText(last?.content).trim();
    if (text.length > 0) return text;
  }
  if (Array.isArray(entries)) {
    for (let i = entries.length - 1; i >= 0; i--) {
      const e = entries[i] as { type?: string; message?: { role?: string; content?: unknown } };
      if (e && e.type === "message" && e.message?.role === "assistant") {
        const text = extractText(e.message.content).trim();
        if (text.length > 0) return text;
      }
    }
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

export function buildState(eventOrText: { text: string } | string, ctx: ExtensionContext): GuardState | undefined {
  let entries: unknown[] = [];
  try {
    entries = ctx.sessionManager.getEntries() as unknown[];
  } catch {
    return undefined;
  }
  let lastCompaction: string | null = null;
  let messageCount = 0;
  let sinceCompaction: number | null = null;
  for (const entry of entries) {
    const e = entry as { type?: string; summary?: string };
    if (e.type === "compaction") {
      lastCompaction = e.summary ? e.summary.slice(0, 120) : "(summary unavailable)";
      sinceCompaction = 0;
    }
    if (e.type === "message") {
      messageCount += 1;
      if (sinceCompaction !== null) sinceCompaction += 1;
    }
  }
  const usage = (() => {
    try { return ctx.getContextUsage(); } catch { return null; }
  })();
  const currentText = typeof eventOrText === "string" ? eventOrText : eventOrText.text;
  return {
    context: {
      tokens: usage ? usage.tokens : null,
      window: usage ? usage.contextWindow : 0,
      percent: usage ? usage.percent : null,
      messages: messageCount,
    },
    model: ctx.model ? ctx.model.provider + "/" + ctx.model.id : "unknown",
    session: { entries: entries.length, messages: messageCount, lastCompaction, sinceCompaction },
    recentMessages: recentMessagesFrom(entries, 12),
    currentInput: (currentText || "").slice(0, 600),
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
      "Given context (tokens used, window, percent, and messages carried in state) and recentMessages, is compacting NOW worth it? " +
      "Judge by usefulness rather than a token fraction: is the recent work settled enough to summarize, is most of the carried context stale for the current work, and would a summary keep what is needed for the next step? " +
      "Compacting now is worth it when the accumulated context is mostly historical and the work has reached a clean settling point. " +
      "Keep going when the work is mid-flight or the carried context remains live and relevant.",
    criteria: {
      "compact-now": "Compacting now is worth it: recent work is settled enough to summarize, most carried context is stale for the next step, and a summary will preserve all necessary state.",
      soon: "Context is accumulating and compaction will be needed soon, but either the current topic is not yet cleanly settled or the carried context still has active value.",
      "keep-going": "Keep going without compacting: work is mid-flight, carried context is live and active, or the exchange is still fresh enough that summarizing now would lose useful detail.",
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

export function retryDelayMs(): number {
  const n = Number(process.env.PI_JEV_GUARD_RETRY_DELAY_MS || "750");
  return Number.isFinite(n) && n >= 0 ? n : 750;
}

export async function askJevWithRetry(
  apiKey: string,
  state: unknown,
  questions: Record<string, Question>,
  signal: AbortSignal | undefined,
  timeoutMs: number,
  onAttempt?: (attempt: number, err?: Error) => void,
): Promise<AskResponse> {
  let lastErr: Error = new Error("Jev unavailable");
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      if (signal?.aborted === true) throw new Error("aborted before attempt");
      const res = await askJev(apiKey, state, questions, signal, timeoutMs);
      onAttempt?.(attempt);
      return res;
    } catch (err) {
      lastErr = err instanceof Error ? err : new Error(String(err));
      onAttempt?.(attempt, lastErr);
      // Retry once unless the caller aborted (user/turn cancelled).
      if (attempt < 2 && signal?.aborted !== true) {
        const delay = retryDelayMs();
        if (delay > 0) await new Promise((r) => setTimeout(r, delay));
      }
    }
  }
  throw lastErr;
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

// ---------------------------------------------------------------------------
// Engram persistence: a real HTTP save against the running local server.
// The input/session hooks have no executeTool, so we talk to Engram directly
// (same flow gentle-engram uses: resolve project -> ensure session -> save).
// ---------------------------------------------------------------------------

const ENGRAM_URL = process.env.ENGRAM_URL || "http://127.0.0.1:" + (process.env.ENGRAM_PORT || "7437");

export interface EngramSaveOptions {
  sessionId: string;
  cwd: string;
  title: string;
  content: string;
  type?: string;
  signal?: AbortSignal;
  timeoutMs?: number;
}

async function engramJson(
  path: string,
  init: { method: string; body?: unknown },
  signal: AbortSignal | undefined,
  timeoutMs: number,
): Promise<{ ok: boolean; status: number; body: unknown }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const forward = () => controller.abort();
  signal?.addEventListener("abort", forward, { once: true });
  try {
    const res = await fetch(ENGRAM_URL + path, {
      method: init.method,
      headers: init.body !== undefined ? { "content-type": "application/json" } : undefined,
      body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
      signal: controller.signal,
    });
    let body: unknown = null;
    try { body = await res.json(); } catch { body = null; }
    return { ok: res.ok, status: res.status, body };
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", forward);
  }
}

export async function saveToEngramDirect(opts: EngramSaveOptions): Promise<{ saved: boolean; observationId?: number; project?: string; reason?: string }> {
  const timeoutMs = opts.timeoutMs ?? 5000;
  // 1. Resolve the project from the cwd (server-side git detection).
  const projectRes = await engramJson(
    "/project/current?" + new URLSearchParams({ cwd: opts.cwd }).toString(),
    { method: "GET" },
    opts.signal,
    timeoutMs,
  );
  if (!projectRes.ok) return { saved: false, reason: "project_resolve_http_" + projectRes.status };
  const projectBody = projectRes.body as { project?: string } | null;
  const project = projectBody?.project;
  if (!project || typeof project !== "string") {
    return { saved: false, reason: "project_unresolved" };
  }
  // 2. Ensure the runtime session exists in Engram (idempotent-ish).
  const sessionRes = await engramJson(
    "/sessions",
    { method: "POST", body: { id: opts.sessionId, project, directory: opts.cwd, ownership_mode: "project_owned" } },
    opts.signal,
    timeoutMs,
  );
  if (!sessionRes.ok && sessionRes.status !== 409) {
    return { saved: false, project, reason: "session_register_http_" + sessionRes.status };
  }
  // 3. Save the observation (capture_prompt false: this is a judgement, not a transcript).
  const saveRes = await engramJson(
    "/observations",
    {
      method: "POST",
      body: {
        session_id: opts.sessionId,
        title: opts.title,
        content: opts.content,
        type: opts.type || "jev_guard",
        project,
        scope: "project",
        capture_prompt: false,
      },
    },
    opts.signal,
    timeoutMs,
  );
  if (!saveRes.ok) return { saved: false, project, reason: "observation_http_" + saveRes.status };
  const receipt = saveRes.body as { id?: number } | null;
  return { saved: true, project, observationId: typeof receipt?.id === "number" ? receipt.id : undefined };
}

export function buildEngramTitle(state: GuardState, reason: string): string {
  const input = state.currentInput.replace(/\s+/g, " ").trim().slice(0, 80);
  return "Jev guard: " + (input || "(no input)") + (reason ? " - " + reason.slice(0, 60) : "");
}

export function buildEngramContent(state: GuardState, reason: string): string {
  const transcript = state.recentMessages
    .map((m) => m.role + ": " + m.text)
    .join("\n");
  return [
    "Why Jev flagged this: " + reason,
    "Current input: " + state.currentInput,
    "Recent messages:",
    transcript,
  ].join("\n\n").slice(0, 8000);
}
export interface GuardActionOutcome {
  action: "compact" | "cooldown" | "mid-task-waiting" | "just-compacted" | "none";
  compacted: boolean;
  notified: string[];
  instructions?: string;
}

export function evaluateCompactionAction(
  d: Decisions,
  now: number,
  lastAutoCompact: number,
  cooldownMs: number,
  postCompaction?: { messagesSinceCompaction: number | null },
): GuardActionOutcome {
  const notified: string[] = [];
  // Justo después de una compactación el contexto *es* el resumen: volver a
  // compactar no aporta y Pi lo rechaza ("Already compacted"). Se exige al
  // menos un intercambio completo posterior antes de considerar otra.
  const since = postCompaction?.messagesSinceCompaction;
  if (d.compactionUrgency === "compact-now" && typeof since === "number" && since <= 2) {
    return { action: "just-compacted", compacted: false, notified };
  }
  if (d.compactionUrgency === "compact-now" && d.taskState === "settled") {
    if (now - lastAutoCompact > cooldownMs) {
      const instructions = buildCompactionInstructions(d);
      notified.push("Jev: context is heavy and the task is settled - compacting now.");
      return { action: "compact", compacted: true, instructions: instructions || undefined, notified };
    } else {
      notified.push("Jev: compact-now (cooldown active) - manual /compact is available.");
      return { action: "cooldown", compacted: false, notified };
    }
  } else if (d.compactionUrgency === "compact-now" && d.taskState === "mid-task") {
    notified.push("Jev: context is heavy but the task is mid-flight - waiting for a settled moment.");
    return { action: "mid-task-waiting", compacted: false, notified };
  }
  return { action: "none", compacted: false, notified };
}

export const AUTO_COMPACT_COOLDOWN_MS = 5 * 60 * 1000;
export const GUARD_DEBOUNCE_MS = 10_000;

export async function runGuardTurn(
  source: "input" | "agent_end",
  text: string,
  ctx: ExtensionContext,
  deps: {
    getKey: () => Promise<string | undefined>;
    lastAdvice: { at: number; session: string };
    lastAutoCompact: number;
    cooldownMs?: number;
    debounceMs?: number;
    onCompactError?: (error: string, at: number) => void;
    askJevFn?: typeof askJevWithRetry;
    traceFn?: typeof trace;
    notifyFn?: (ctx: ExtensionContext, message: string, type: "info" | "warning" | "error") => void;
    saveEngramFn?: typeof saveToEngramDirect;
  },
): Promise<{ ran: boolean; lastAdvice: { at: number; session: string }; lastAutoCompact: number }> {
  let { lastAdvice, lastAutoCompact } = deps;
  const cooldownMs = deps.cooldownMs ?? AUTO_COMPACT_COOLDOWN_MS;
  const debounceMs = deps.debounceMs ?? GUARD_DEBOUNCE_MS;
  const askFn = deps.askJevFn ?? askJevWithRetry;
  const traceFn = deps.traceFn ?? trace;
  const notifyFn = deps.notifyFn ?? ((c, msg, type) => { try { c.ui.notify(msg, type); } catch { /* best-effort */ } });
  const saveEngram = deps.saveEngramFn ?? saveToEngramDirect;

  const key = await deps.getKey();
  if (!key) return { ran: false, lastAdvice, lastAutoCompact };

  const state = buildState(text, ctx);
  if (!state) return { ran: false, lastAdvice, lastAutoCompact };

  const now = Date.now();
  if (now - lastAdvice.at < debounceMs) return { ran: false, lastAdvice, lastAutoCompact };

  try {
    const timeoutMs = Number(process.env.PI_JEV_GUARD_TIMEOUT_MS || "4000");
    const response = await askFn(key, state, QUESTIONS, ctx.signal, timeoutMs, (attempt, err) => {
      if (err && attempt < 2) void traceFn({ event: "jev_retry", attempt, error: err.message.slice(0, 200) });
      else if (err && attempt === 2) void traceFn({ event: "jev_retry_exhausted", attempt, error: err.message.slice(0, 200) });
    });
    const d = decide(response.answers);
    lastAdvice = { at: now, session: d.sessionAdvice };

    await traceFn({
      event: source === "input" ? "input_judged" : "response_judged",
      tokens: state.context.tokens,
      percent: state.context.percent,
      task: d.taskState,
      compaction: d.compactionUrgency,
      session: d.sessionAdvice,
      saveToEngram: d.saveToEngram,
      sinceCompaction: state.session.sinceCompaction,
      usage: response.usage,
    });

    const action = evaluateCompactionAction(d, now, lastAutoCompact, cooldownMs, {
      messagesSinceCompaction: state.session.sinceCompaction,
    });
    void traceFn({ event: "compaction_action", action: action.action });
    for (const msg of action.notified) {
      notifyFn(ctx, msg, "info");
    }
    if (action.compacted) {
      lastAutoCompact = now;
      ctx.compact({
        customInstructions: action.instructions,
        onComplete: () => traceFn({ event: "auto_compacted", reason: "jev_compact_now" }),
        onError: (err) => {
          const message = err.message.slice(0, 200);
          deps.onCompactError?.(message, Date.now());
          // "Already compacted" no es un fallo: la sesión ya está compactada y
          // reintentar en el siguiente turno solo repite el error en pantalla.
          const benign = /already compacted/i.test(err.message);
          void traceFn({ event: benign ? "auto_compact_rejected" : "auto_compact_error", error: message });
        },
      });
    }

    if (d.saveToEngram) {
      const sessionId = (() => {
        try { return ctx.sessionManager.getSessionId(); } catch { return ""; }
      })();
      const cwd = ctx.cwd;
      if (sessionId) {
        const savePromise = saveEngram({
          sessionId,
          cwd,
          title: buildEngramTitle(state, d.saveReason),
          content: buildEngramContent(state, d.saveReason),
          signal: ctx.signal,
        }).then((res) => {
          if (res.saved) {
            traceFn({
              event: "engram_saved",
              project: res.project,
              observationId: res.observationId,
              reason: d.saveReason,
            });
            notifyFn(ctx, "Jev: saved to Engram (" + (res.project ?? "unknown") + "#" + (res.observationId ?? "?") + ").", "info");
          } else {
            traceFn({ event: "engram_save_failed", reason: res.reason, project: res.project });
            notifyFn(ctx, "Jev: Engram save failed (" + (res.reason ?? "unknown") + ").", "warning");
          }
        });
        void savePromise.catch(() => {});
      } else {
        await traceFn({ event: "engram_save_skipped", reason: "no_session_id" });
        notifyFn(ctx, "Jev: Engram save skipped (no runtime session id).", "warning");
      }
    }

    // El consejo de sesión nueva solo cuando NO se compacta: pedir compactación y
    // sugerir empezar de cero en el mismo turno se contradice.
    if (d.sessionAdvice === "new-session" && d.compactionUrgency === "compact-now" && !action.compacted) {
      notifyFn(ctx, "Jev: a fresh session may be cleaner than continuing compacted. Your call.", "info");
    }

    return { ran: true, lastAdvice, lastAutoCompact };
  } catch (error) {
    await traceFn({
      event: source === "input" ? "input_error" : "response_error",
      error: String(error instanceof Error ? error.message : error).slice(0, 200),
    });
    return { ran: false, lastAdvice, lastAutoCompact };
  }
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

  // 1. Every user message: one batched Jev request.
  pi.on("input", async (event: { text: string; streamingBehavior?: string }, ctx: ExtensionContext) => {
    if (event.streamingBehavior) return { action: "continue" as const };
    const res = await runGuardTurn("input", event.text, ctx, {
      getKey,
      lastAdvice,
      lastAutoCompact,
      notifyFn: notify,
      onCompactError: (_error, at) => { lastAutoCompact = at; },
    });
    lastAdvice = res.lastAdvice;
    lastAutoCompact = res.lastAutoCompact;
    return { action: "continue" as const };
  });

  // 2. Once per completed assistant response: one batched Jev request.
  // agent_end fires when the agent loop finishes all turns in the run,
  // making it the exact completed response boundary (firing least often).
  pi.on("agent_end", async (event: AgentEndEvent, ctx: ExtensionContext) => {
    let entries: unknown[] = [];
    try { entries = ctx.sessionManager.getEntries() as unknown[]; } catch { /* best-effort */ }
    const text = latestAssistantText(event.messages, entries);
    const res = await runGuardTurn("agent_end", text, ctx, {
      getKey,
      lastAdvice,
      lastAutoCompact,
      notifyFn: notify,
      onCompactError: (_error, at) => { lastAutoCompact = at; },
    });
    lastAdvice = res.lastAdvice;
    lastAutoCompact = res.lastAutoCompact;
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
      const response = await askJevWithRetry(
        key,
        state,
        { mid_task: QUESTIONS.mid_task, session_fresh: QUESTIONS.session_fresh },
        event.signal,
        timeoutMs,
        (attempt, err) => {
          if (err && attempt < 2) void trace({ event: "before_compact_retry", attempt, error: err.message.slice(0, 200) });
          else if (err && attempt === 2) void trace({ event: "before_compact_retry_exhausted", attempt, error: err.message.slice(0, 200) });
        },
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
    // Cualquier compactación arma el cooldown, no solo la que decide el guard:
    // las manuales y las de umbral también dejan la sesión recién compactada.
    lastAutoCompact = Date.now();
    if (lastAdvice.session === "new-session") {
      notify(ctx, "Jev: after that compaction, a fresh session may be cleaner. Your call.", "info");
    }
    await trace({ event: "compacted", reason: event.reason, sessionAdvice: lastAdvice.session });
  });
}
