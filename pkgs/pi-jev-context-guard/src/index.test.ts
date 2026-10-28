import { test } from "node:test";
import assert from "node:assert/strict";
import {
  decide,
  extractText,
  recentMessagesFrom,
  latestAssistantText,
  buildState,
  buildCompactionInstructions,
  evaluateCompactionAction,
  runGuardTurn,
  QUESTIONS,
  askJev,
  askJevWithRetry,
  retryDelayMs,
  saveToEngramDirect,
  buildEngramTitle,
  buildEngramContent,
} from "./index.ts";

// --- extractText -----------------------------------------------------------

test("extractText returns plain string content", () => {
  assert.equal(extractText("hello"), "hello");
});

test("extractText joins text blocks from array content", () => {
  const content = [
    { type: "text", text: "first" },
    { type: "image" },
    { type: "text", text: "second" },
  ];
  assert.equal(extractText(content), "first second");
});

test("extractText returns empty for non-text", () => {
  assert.equal(extractText(null), "");
  assert.equal(extractText(undefined), "");
  assert.equal(extractText(42), "");
  assert.equal(extractText([{ type: "image" }]), "");
});

// --- recentMessagesFrom -----------------------------------------------------

const makeEntries = () => [
  { type: "message", message: { role: "user", content: "fix the bug" } },
  { type: "message", message: { role: "assistant", content: [{ type: "text", text: "done" }] } },
  { type: "compaction", summary: "earlier work summary" },
  { type: "message", message: { role: "tool", content: [{ type: "toolResult", text: "noise" }] } },
  { type: "message", message: { role: "user", content: "now do X" } },
  { type: "usage", kind: "cache_warm" },
];

test("recentMessagesFrom keeps only user/assistant messages", () => {
  const recent = recentMessagesFrom(makeEntries(), 12);
  assert.equal(recent.length, 3);
  assert.deepEqual(recent.map((m) => m.role), ["user", "assistant", "user"]);
  assert.equal(recent[0].text, "fix the bug");
  assert.equal(recent[1].text, "done");
  assert.equal(recent[2].text, "now do X");
});

test("recentMessagesFrom respects the limit", () => {
  const entries = Array.from({ length: 30 }, (_, i) => ({
    type: "message",
    message: { role: "user", content: "msg " + i },
  }));
  const recent = recentMessagesFrom(entries, 12);
  assert.equal(recent.length, 12);
  assert.equal(recent[recent.length - 1].text, "msg 29");
  assert.equal(recent[0].text, "msg 18");
});

test("recentMessagesFrom returns empty for no messages", () => {
  assert.deepEqual(recentMessagesFrom([], 12), []);
  assert.deepEqual(recentMessagesFrom([{ type: "compaction" }], 12), []);
});

// --- QUESTIONS --------------------------------------------------------------

test("QUESTIONS has the four expected ids", () => {
  assert.deepEqual(Object.keys(QUESTIONS).sort(), ["heavy_context", "mid_task", "session_fresh", "worth_memory"]);
});

test("QUESTIONS have valid types", () => {
  assert.equal(QUESTIONS.mid_task.type, "noul");
  assert.equal(QUESTIONS.worth_memory.type, "noul");
  assert.equal(QUESTIONS.heavy_context.type, "choice");
  assert.equal(QUESTIONS.session_fresh.type, "choice");
});

test("QUESTIONS choice criteria match decision strings", () => {
  const heavyKeys = Object.keys(QUESTIONS.heavy_context.criteria || {});
  assert.ok(heavyKeys.includes("compact-now"));
  assert.ok(heavyKeys.includes("soon"));
  assert.ok(heavyKeys.includes("keep-going"));
  const freshKeys = Object.keys(QUESTIONS.session_fresh.criteria || {});
  assert.ok(freshKeys.includes("new-session"));
  assert.ok(freshKeys.includes("continue"));
});

test("QUESTIONS.heavy_context has no percentage anchors and uses usefulness criteria", () => {
  const instructions = QUESTIONS.heavy_context.instructions;
  const criteria = JSON.stringify(QUESTIONS.heavy_context.criteria || {});
  assert.ok(!instructions.includes("%"), "instructions must not contain %");
  assert.ok(!criteria.includes("%"), "criteria must not contain %");
  assert.ok(!criteria.includes("85"), "criteria must not contain 85");
  assert.ok(!criteria.includes("60"), "criteria must not contain 60");
  assert.ok(instructions.includes("settled"), "instructions must mention settled");
  assert.ok(instructions.includes("stale"), "instructions must mention stale");
  assert.ok(instructions.includes("summary"), "instructions must mention summary");
  assert.ok(instructions.includes("mid-flight"), "instructions must mention mid-flight");
});

const noul = (n: number) => ({ type: "noul" as const, noul: n });
const choice = (c: string) => ({ type: "choice" as const, choice: c, probabilities: {}, confidence: 0.9 });

test("decide: mid-task detected", () => {
  const d = decide({ mid_task: noul(0.8), worth_memory: noul(0.1), heavy_context: choice("compact-now"), session_fresh: choice("continue") });
  assert.equal(d.taskState, "mid-task");
});

test("decide: settled detected", () => {
  const d = decide({ mid_task: noul(0.2), worth_memory: noul(0.1), heavy_context: choice("compact-now"), session_fresh: choice("continue") });
  assert.equal(d.taskState, "settled");
});

test("decide: memory-worthy surfaces saveToEngram with reason", () => {
  const d = decide({ mid_task: noul(0.8), worth_memory: noul(0.7), heavy_context: choice("keep-going"), session_fresh: choice("continue") });
  assert.equal(d.saveToEngram, true);
  assert.ok(d.saveReason.length > 0);
});

test("decide: not memory-worthy gives no reason", () => {
  const d = decide({ mid_task: noul(0.2), worth_memory: noul(0.3), heavy_context: choice("keep-going"), session_fresh: choice("continue") });
  assert.equal(d.saveToEngram, false);
  assert.equal(d.saveReason, "");
});

test("decide: session_fresh passes through", () => {
  const d = decide({ mid_task: noul(0.2), worth_memory: noul(0.1), heavy_context: choice("keep-going"), session_fresh: choice("new-session") });
  assert.equal(d.sessionAdvice, "new-session");
});

test("decide: missing answers fail safe", () => {
  const d = decide({});
  assert.equal(d.saveToEngram, false);
  assert.equal(d.compactionUrgency, "unknown");
  assert.equal(d.sessionAdvice, "unknown");
  assert.equal(d.taskState, "settled");
});

test("decide: compactionUrgency passes through", () => {
  const d1 = decide({ heavy_context: choice("compact-now") });
  assert.equal(d1.compactionUrgency, "compact-now");
  const d2 = decide({ heavy_context: choice("soon") });
  assert.equal(d2.compactionUrgency, "soon");
  const d3 = decide({ heavy_context: choice("keep-going") });
  assert.equal(d3.compactionUrgency, "keep-going");
});

// --- buildCompactionInstructions -------------------------------------------

test("buildCompactionInstructions: mid-task preserves live state", () => {
  const d = decide({ mid_task: noul(0.8), heavy_context: choice("compact-now"), session_fresh: choice("continue") });
  const instr = buildCompactionInstructions(d);
  assert.ok(instr.includes("mid-flight"), instr);
  assert.ok(instr.includes("failing tests"), instr);
  assert.ok(instr.includes("next concrete step"), instr);
});

test("buildCompactionInstructions: new-session adds handoff block", () => {
  const d = decide({ mid_task: noul(0.2), heavy_context: choice("compact-now"), session_fresh: choice("new-session") });
  const instr = buildCompactionInstructions(d);
  assert.ok(instr.includes("fresh session"), instr);
  assert.ok(instr.includes("handoff block"), instr);
});

test("buildCompactionInstructions: both mid-task and new-session", () => {
  const d = decide({ mid_task: noul(0.7), heavy_context: choice("compact-now"), session_fresh: choice("new-session") });
  const instr = buildCompactionInstructions(d);
  assert.ok(instr.includes("mid-flight"), instr);
  assert.ok(instr.includes("handoff block"), instr);
});

test("buildCompactionInstructions: settled + continue gives empty string", () => {
  const d = decide({ mid_task: noul(0.1), heavy_context: choice("compact-now"), session_fresh: choice("continue") });
  const instr = buildCompactionInstructions(d);
  assert.equal(instr, "");
});

// --- saveToEngramDirect -----------------------------------------------------

const makeEngramFetch = (responses: { status: number; body: unknown }[]) => {
  const calls: { url: string; init: RequestInit }[] = [];
  let i = 0;
  const fn = async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const r = responses[Math.min(i, responses.length - 1)];
    i += 1;
    return new Response(JSON.stringify(r.body), { status: r.status });
  };
  return { fn, calls };
};

test("saveToEngramDirect: resolves project, registers session, saves observation", async () => {
  const fake = makeEngramFetch([
    { status: 200, body: { project: "loon-flakes" } },
    { status: 201, body: { status: "created" } },
    { status: 201, body: { id: 42, status: "saved" } },
  ]);
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fake.fn;
  try {
    const res = await saveToEngramDirect({
      sessionId: "sess-1",
      cwd: "/home/loonbac/.nixos",
      title: "t",
      content: "c",
    });
    assert.equal(res.saved, true);
    assert.equal(res.project, "loon-flakes");
    assert.equal(res.observationId, 42);
    assert.equal(fake.calls.length, 3);
    assert.ok(fake.calls[0].url.includes("/project/current"));
    assert.ok(fake.calls[1].url.endsWith("/sessions"));
    assert.ok(fake.calls[2].url.endsWith("/observations"));
    const obsBody = JSON.parse(fake.calls[2].init.body as string);
    assert.equal(obsBody.session_id, "sess-1");
    assert.equal(obsBody.project, "loon-flakes");
    assert.equal(obsBody.capture_prompt, false);
    assert.equal(obsBody.type, "jev_guard");
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

test("saveToEngramDirect: tolerates 409 on session (already registered)", async () => {
  const fake = makeEngramFetch([
    { status: 200, body: { project: "p" } },
    { status: 409, body: { error: "exists" } },
    { status: 201, body: { id: 7 } },
  ]);
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fake.fn;
  try {
    const res = await saveToEngramDirect({ sessionId: "s", cwd: "/tmp", title: "t", content: "c" });
    assert.equal(res.saved, true);
    assert.equal(res.observationId, 7);
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

test("saveToEngramDirect: fails without saving when project unresolved", async () => {
  const fake = makeEngramFetch([{ status: 200, body: { project_source: "ambiguous" } }]);
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fake.fn;
  try {
    const res = await saveToEngramDirect({ sessionId: "s", cwd: "/tmp", title: "t", content: "c" });
    assert.equal(res.saved, false);
    assert.equal(res.reason, "project_unresolved");
    assert.equal(fake.calls.length, 1); // no session/observation attempt
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

test("saveToEngramDirect: reports observation HTTP failure", async () => {
  const fake = makeEngramFetch([
    { status: 200, body: { project: "p" } },
    { status: 201, body: { status: "created" } },
    { status: 500, body: { error: "boom" } },
  ]);
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fake.fn;
  try {
    const res = await saveToEngramDirect({ sessionId: "s", cwd: "/tmp", title: "t", content: "c" });
    assert.equal(res.saved, false);
    assert.equal(res.reason, "observation_http_500");
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

test("buildEngramTitle includes a snippet of the current input", () => {
  const title = buildEngramTitle(
    { currentInput: "fix the nix module", recentMessages: [] } as never,
    "A durable lesson looks present",
  );
  assert.ok(title.includes("fix the nix module"), title);
  assert.ok(title.includes("A durable lesson"), title);
});

test("buildEngramContent joins transcript and reason", () => {
  const content = buildEngramContent(
    {
      currentInput: "do X",
      recentMessages: [
        { role: "user", text: "fix the bug" },
        { role: "assistant", text: "done" },
      ],
    } as never,
    "root cause found",
  );
  assert.ok(content.includes("root cause found"), content);
  assert.ok(content.includes("fix the bug"), content);
  assert.ok(content.includes("done"), content);
  assert.ok(content.includes("do X"), content);
});
// --- askJevWithRetry --------------------------------------------------------

test("askJevWithRetry: succeeds on first attempt without retry", async () => {
  const fake = makeEngramFetch([{ status: 200, body: { answers: {}, usage: { input_tokens: 1, output_tokens: 1 } } }]);
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fake.fn;
  const prevDelay = process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
  process.env.PI_JEV_GUARD_RETRY_DELAY_MS = "0";
  try {
    const res = await askJevWithRetry("k", {}, QUESTIONS, undefined, 1000);
    assert.ok(res);
    assert.equal(fake.calls.length, 1);
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
    if (prevDelay === undefined) delete process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
    else process.env.PI_JEV_GUARD_RETRY_DELAY_MS = prevDelay;
  }
});

test("askJevWithRetry: retries once after failure then succeeds", async () => {
  const fake = makeEngramFetch([
    { status: 500, body: { error: "boom" } },
    { status: 200, body: { answers: {}, usage: { input_tokens: 1, output_tokens: 1 } } },
  ]);
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fake.fn;
  const prevDelay = process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
  process.env.PI_JEV_GUARD_RETRY_DELAY_MS = "0";
  try {
    const res = await askJevWithRetry("k", {}, QUESTIONS, undefined, 1000);
    assert.ok(res);
    assert.equal(fake.calls.length, 2);
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
    if (prevDelay === undefined) delete process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
    else process.env.PI_JEV_GUARD_RETRY_DELAY_MS = prevDelay;
  }
});

test("askJevWithRetry: throws after two failed attempts, tracing both", async () => {
  const fake = makeEngramFetch([
    { status: 500, body: {} },
    { status: 500, body: {} },
  ]);
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fake.fn;
  const prevDelay = process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
  process.env.PI_JEV_GUARD_RETRY_DELAY_MS = "0";
  const attempts: number[] = [];
  const errors: string[] = [];
  try {
    await assert.rejects(
      () => askJevWithRetry("k", {}, QUESTIONS, undefined, 1000, (a, e) => { attempts.push(a); if (e) errors.push(e.message); }),
      /Jev HTTP 500/,
    );
    assert.deepEqual(attempts, [1, 2]);
    assert.equal(fake.calls.length, 2);
    assert.equal(errors.length, 2);
    assert.ok(errors.every((m) => m.length <= 200));
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
    if (prevDelay === undefined) delete process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
    else process.env.PI_JEV_GUARD_RETRY_DELAY_MS = prevDelay;
  }
});

test("askJevWithRetry: caller abort during the call stops the retry", async () => {
  // Abort the outer signal while the first fetch is in flight: the retry must not run.
  const controller = new AbortController();
  let calls = 0;
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = (async () => {
    calls += 1;
    if (calls === 1) controller.abort();
    throw new Error("aborted");
  }) as unknown as typeof fetch;
  const prevDelay = process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
  process.env.PI_JEV_GUARD_RETRY_DELAY_MS = "0";
  try {
    await assert.rejects(() => askJevWithRetry("k", {}, QUESTIONS, controller.signal, 1000));
    assert.equal(calls, 1);
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
    if (prevDelay === undefined) delete process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
    else process.env.PI_JEV_GUARD_RETRY_DELAY_MS = prevDelay;
  }
});

test("retryDelayMs reads env and falls back", () => {
  const prev = process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
  try {
    delete process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
    assert.equal(retryDelayMs(), 750);
    process.env.PI_JEV_GUARD_RETRY_DELAY_MS = "0";
    assert.equal(retryDelayMs(), 0);
    process.env.PI_JEV_GUARD_RETRY_DELAY_MS = "abc";
    assert.equal(retryDelayMs(), 750);
  } finally {
    if (prev === undefined) delete process.env.PI_JEV_GUARD_RETRY_DELAY_MS;
    else process.env.PI_JEV_GUARD_RETRY_DELAY_MS = prev;
  }
});
// --- askJev -----------------------------------------------------------------

test("askJev sends state, model, and questions to the wire", async () => {
  const calls: unknown[] = [];
  const fakeFetch = async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return new Response(
      JSON.stringify({
        model: "jev-latest",
        answers: { mid_task: { type: "noul", noul: 0.8 } },
        usage: { input_tokens: 100, output_tokens: 20 },
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = fakeFetch;
  try {
    const resp = await askJev(
      "test-key",
      { currentInput: "hello" },
      { mid_task: QUESTIONS.mid_task },
      undefined,
      4000,
    );
    assert.equal(calls.length, 1);
    const call = calls[0] as { url: string; init: RequestInit };
    assert.equal(call.url, "https://api.typesafe.ai/v1/systemone");
    const headers = call.init.headers as Record<string, string>;
    assert.equal(headers.authorization, "Bearer test-key");
    assert.equal(headers["content-type"], "application/json");
    const body = JSON.parse(call.init.body as string);
    assert.equal(body.model, "jev-latest");
    assert.ok(body.state.currentInput === "hello");
    assert.ok(body.questions.mid_task);
    assert.equal(resp.answers.mid_task.noul, 0.8);
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

test("askJev throws on non-OK status", async () => {
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = async () =>
    new Response("rate limited", { status: 429 });
  try {
    await assert.rejects(
      askJev("k", {}, { mid_task: QUESTIONS.mid_task }, undefined, 4000),
      /Jev HTTP 429/,
    );
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

test("askJev throws on malformed response", async () => {
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = async () =>
    new Response(JSON.stringify({ noAnswers: true }), { status: 200 });
  try {
    await assert.rejects(
      askJev("k", {}, { mid_task: QUESTIONS.mid_task }, undefined, 4000),
      /malformed/,
    );
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

test("askJev respects AbortSignal", async () => {
  const controller = new AbortController();
  const orig = globalThis.fetch;
  (globalThis as { fetch: unknown }).fetch = async (_url: string, init: RequestInit) => {
    return new Promise((_resolve, reject) => {
      init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    });
  };
  try {
    const promise = askJev("k", {}, { mid_task: QUESTIONS.mid_task }, controller.signal, 60_000);
    controller.abort();
    await assert.rejects(promise, /abort/i);
  } finally {
    (globalThis as { fetch: unknown }).fetch = orig;
  }
});

// --- latestAssistantText ----------------------------------------------------

test("latestAssistantText extracts text from messages array", () => {
  const messages = [
    { role: "user", content: "hello" },
    { role: "assistant", content: "I fixed the issue." },
  ];
  assert.equal(latestAssistantText(messages, []), "I fixed the issue.");
});

test("latestAssistantText extracts text from array content in message", () => {
  const messages = [
    { role: "assistant", content: [{ type: "text", text: "Done with refactor." }] },
  ];
  assert.equal(latestAssistantText(messages, []), "Done with refactor.");
});

test("latestAssistantText falls back to session entries when messages has no assistant", () => {
  const entries = [
    { type: "message", message: { role: "assistant", content: "Earlier response" } },
    { type: "message", message: { role: "user", content: "thanks" } },
  ];
  assert.equal(latestAssistantText([], entries), "Earlier response");
});

test("latestAssistantText returns empty string when no assistant message exists", () => {
  assert.equal(latestAssistantText([], []), "");
  assert.equal(latestAssistantText(undefined, []), "");
});

// --- buildState -------------------------------------------------------------

test("buildState counts messages and populates GuardState", () => {
  const entries = [
    { type: "message", message: { role: "user", content: "hi" } },
    { type: "message", message: { role: "assistant", content: "hello" } },
    { type: "compaction", summary: "compaction summary" },
    { type: "usage" },
  ];
  const fakeCtx = {
    sessionManager: { getEntries: () => entries },
    getContextUsage: () => ({ tokens: 50_000, contextWindow: 200_000, percent: 25 }),
    model: { provider: "test", id: "m1" },
  } as never;

  const state1 = buildState({ text: "user prompt" }, fakeCtx);
  assert.ok(state1);
  assert.equal(state1.currentInput, "user prompt");
  assert.equal(state1.session.messages, 2);
  assert.equal(state1.context.messages, 2);
  assert.equal(state1.context.tokens, 50_000);
  assert.equal(state1.session.lastCompaction, "compaction summary");

  const state2 = buildState("plain text", fakeCtx);
  assert.ok(state2);
  assert.equal(state2.currentInput, "plain text");
});

// --- evaluateCompactionAction -----------------------------------------------

test("evaluateCompactionAction: compact-now + settled compacts when no cooldown", () => {
  const d = decide({ mid_task: noul(0.1), heavy_context: choice("compact-now"), session_fresh: choice("continue") });
  const outcome = evaluateCompactionAction(d, 100_000, 0, 50_000);
  assert.equal(outcome.compacted, true);
  assert.equal(outcome.action, "compact");
  assert.ok(outcome.notified[0].includes("compacting now"));
});

test("evaluateCompactionAction: compact-now + settled respects cooldown", () => {
  const d = decide({ mid_task: noul(0.1), heavy_context: choice("compact-now"), session_fresh: choice("continue") });
  const outcome = evaluateCompactionAction(d, 100_000, 90_000, 50_000);
  assert.equal(outcome.compacted, false);
  assert.equal(outcome.action, "cooldown");
  assert.ok(outcome.notified[0].includes("cooldown active"));
});

test("evaluateCompactionAction: compact-now + mid-task refuses to compact", () => {
  const d = decide({ mid_task: noul(0.8), heavy_context: choice("compact-now"), session_fresh: choice("continue") });
  const outcome = evaluateCompactionAction(d, 100_000, 0, 50_000);
  assert.equal(outcome.compacted, false);
  assert.equal(outcome.action, "mid-task-waiting");
  assert.ok(outcome.notified[0].includes("waiting for a settled moment"));
});

test("evaluateCompactionAction: keep-going does not compact", () => {
  const d = decide({ mid_task: noul(0.1), heavy_context: choice("keep-going"), session_fresh: choice("continue") });
  const outcome = evaluateCompactionAction(d, 100_000, 0, 50_000);
  assert.equal(outcome.compacted, false);
  assert.equal(outcome.action, "none");
});

// --- runGuardTurn -----------------------------------------------------------

test("runGuardTurn: executes for agent_end when not debounced", async () => {
  let asked = false;
  let compacted = false;
  const traces: Record<string, unknown>[] = [];
  const notifications: string[] = [];

  const fakeCtx = {
    sessionManager: {
      getEntries: () => [{ type: "message", message: { role: "assistant", content: "Done" } }],
      getSessionId: () => "sess-1",
    },
    getContextUsage: () => ({ tokens: 100_000, contextWindow: 1_000_000, percent: 10 }),
    model: { provider: "test", id: "m" },
    cwd: "/tmp",
    compact: (opts?: { onComplete?: () => void }) => {
      compacted = true;
      opts?.onComplete?.();
    },
    ui: { notify: (msg: string) => { notifications.push(msg); } },
  } as never;

  const fakeAsk = async () => {
    asked = true;
    return {
      model: "jev-latest",
      answers: {
        mid_task: noul(0.2),
        worth_memory: noul(0.8),
        heavy_context: choice("compact-now"),
        session_fresh: choice("continue"),
      },
      usage: { input_tokens: 10, output_tokens: 5 },
    };
  };

  const res = await runGuardTurn("agent_end", "Done with work", fakeCtx, {
    getKey: async () => "key-123",
    lastAdvice: { at: 0, session: "" },
    lastAutoCompact: 0,
    askJevFn: fakeAsk as never,
    traceFn: async (t) => { traces.push(t); },
    saveEngramFn: async () => ({ saved: true, project: "test", observationId: 1 }),
  });

  assert.equal(res.ran, true);
  assert.equal(asked, true);
  assert.equal(compacted, true);
  assert.ok(traces.some((t) => t.event === "response_judged"));
  assert.ok(traces.some((t) => t.event === "auto_compacted"));
});

test("runGuardTurn: compact-now + mid-task still refuses to compact", async () => {
  let compacted = false;
  const traces: Record<string, unknown>[] = [];
  const notifications: string[] = [];

  const fakeCtx = {
    sessionManager: {
      getEntries: () => [{ type: "message", message: { role: "assistant", content: "Still working" } }],
      getSessionId: () => "sess-1",
    },
    getContextUsage: () => ({ tokens: 100_000, contextWindow: 1_000_000, percent: 10 }),
    model: { provider: "test", id: "m" },
    cwd: "/tmp",
    compact: () => { compacted = true; },
    ui: { notify: (msg: string) => { notifications.push(msg); } },
  } as never;

  const fakeAsk = async () => ({
    model: "jev-latest",
    answers: {
      mid_task: noul(0.9), // mid-task
      worth_memory: noul(0.1),
      heavy_context: choice("compact-now"),
      session_fresh: choice("continue"),
    },
    usage: { input_tokens: 10, output_tokens: 5 },
  });

  const res = await runGuardTurn("agent_end", "in-flight change", fakeCtx, {
    getKey: async () => "key-123",
    lastAdvice: { at: 0, session: "" },
    lastAutoCompact: 0,
    askJevFn: fakeAsk as never,
    traceFn: async (t) => { traces.push(t); },
    notifyFn: (c, msg) => { notifications.push(msg); },
  });

  assert.equal(res.ran, true);
  assert.equal(compacted, false, "must NOT compact while mid-task");
  assert.ok(notifications.some((n) => n.includes("mid-flight - waiting for a settled moment")));
  assert.ok(!traces.some((t) => t.event === "auto_compacted"));
});

test("runGuardTurn: respects 10s debounce across turns", async () => {
  let asked = false;
  const now = Date.now();
  const fakeCtx = {
    sessionManager: { getEntries: () => [] },
    getContextUsage: () => null,
  } as never;

  const res = await runGuardTurn("agent_end", "text", fakeCtx, {
    getKey: async () => "key-123",
    lastAdvice: { at: now - 3_000, session: "" }, // only 3s ago
    lastAutoCompact: 0,
    askJevFn: (async () => { asked = true; }) as never,
  });

  assert.equal(res.ran, false);
  assert.equal(asked, false);
});

// --- post-compaction window -------------------------------------------------

const compactNowSettled = () =>
  decide({ mid_task: noul(0.1), heavy_context: choice("compact-now"), session_fresh: choice("new-session") });

test("buildState reports messages since the last compaction", () => {
  const entries = [
    { type: "message", message: { role: "user", content: "old" } },
    { type: "message", message: { role: "assistant", content: "old reply" } },
    { type: "compaction", summary: "sum" },
    { type: "message", message: { role: "user", content: "hola" } },
    { type: "message", message: { role: "assistant", content: "ok" } },
  ];
  const afterCompaction = buildState("hola", {
    sessionManager: { getEntries: () => entries },
    getContextUsage: () => null,
  } as never);
  assert.ok(afterCompaction);
  assert.equal(afterCompaction.session.sinceCompaction, 2);

  const neverCompacted = buildState("hi", {
    sessionManager: { getEntries: () => [{ type: "message", message: { role: "user", content: "hi" } }] },
    getContextUsage: () => null,
  } as never);
  assert.ok(neverCompacted);
  assert.equal(neverCompacted.session.sinceCompaction, null);
});

test("evaluateCompactionAction: never compacts within the first exchange after a compaction", () => {
  const outcome = evaluateCompactionAction(compactNowSettled(), 1_000_000, 0, 50_000, {
    messagesSinceCompaction: 2,
  });
  assert.equal(outcome.action, "just-compacted");
  assert.equal(outcome.compacted, false);
  assert.equal(outcome.notified.length, 0, "no nagging right after a compaction");
});

test("evaluateCompactionAction: still compacts once the post-compaction window has real work", () => {
  const outcome = evaluateCompactionAction(compactNowSettled(), 1_000_000, 0, 50_000, {
    messagesSinceCompaction: 9,
  });
  assert.equal(outcome.action, "compact");
  assert.equal(outcome.compacted, true);
});

test("runGuardTurn: arms the cooldown when Pi rejects an already-compacted session", async () => {
  const traces: Record<string, unknown>[] = [];
  const notifications: { msg: string; type: string }[] = [];
  let reported: { error: string; at: number } | undefined;

  const fakeCtx = {
    sessionManager: {
      getEntries: () => [{ type: "message", message: { role: "assistant", content: "Done" } }],
      getSessionId: () => "sess-1",
    },
    getContextUsage: () => ({ tokens: 400_000, contextWindow: 1_000_000, percent: 40 }),
    model: { provider: "test", id: "m" },
    cwd: "/tmp",
    compact: (opts?: { onError?: (err: Error) => void }) => {
      opts?.onError?.(new Error("Compaction failed: Already compacted"));
    },
    ui: { notify: (msg: string, type: string) => { notifications.push({ msg, type }); } },
  } as never;

  const res = await runGuardTurn("input", "sigo con lo de antes", fakeCtx, {
    getKey: async () => "key-123",
    lastAdvice: { at: 0, session: "" },
    lastAutoCompact: 0,
    askJevFn: (async () => ({
      model: "jev-latest",
      answers: {
        mid_task: noul(0.1),
        worth_memory: noul(0.1),
        heavy_context: choice("compact-now"),
        session_fresh: choice("new-session"),
      },
      usage: { input_tokens: 10, output_tokens: 5 },
    })) as never,
    traceFn: async (t) => { traces.push(t); },
    saveEngramFn: async () => ({ saved: false, reason: "skipped" }),
    onCompactError: (error, at) => { reported = { error, at }; },
  });

  assert.ok(reported, "the rejection must reach the guard so it can arm the cooldown");
  assert.ok(reported.error.includes("Already compacted"));
  assert.ok(res.lastAutoCompact > 0, "a rejected compaction must arm the cooldown, not retry next turn");
  assert.ok(traces.some((t) => t.event === "auto_compact_rejected"));
  assert.ok(!traces.some((t) => t.event === "auto_compact_error"));
  assert.ok(!notifications.some((n) => n.type === "error"), "a benign rejection is not a user-facing error");
});

test("runGuardTurn: does not suggest a fresh session in the same turn it compacts", async () => {
  const notifications: { msg: string; type: string }[] = [];

  const fakeCtx = {
    sessionManager: {
      getEntries: () => [{ type: "message", message: { role: "assistant", content: "Done" } }],
      getSessionId: () => "sess-1",
    },
    getContextUsage: () => ({ tokens: 600_000, contextWindow: 1_000_000, percent: 60 }),
    model: { provider: "test", id: "m" },
    cwd: "/tmp",
    compact: () => {},
    ui: { notify: (msg: string, type: string) => { notifications.push({ msg, type }); } },
  } as never;

  const res = await runGuardTurn("agent_end", "listo por ahora", fakeCtx, {
    getKey: async () => "key-123",
    lastAdvice: { at: 0, session: "" },
    lastAutoCompact: 0,
    askJevFn: (async () => ({
      model: "jev-latest",
      answers: {
        mid_task: noul(0.1),
        worth_memory: noul(0.1),
        heavy_context: choice("compact-now"),
        session_fresh: choice("new-session"),
      },
      usage: { input_tokens: 10, output_tokens: 5 },
    })) as never,
    traceFn: async () => {},
    saveEngramFn: async () => ({ saved: false, reason: "skipped" }),
  });

  assert.equal(res.ran, true);
  assert.ok(notifications.some((n) => n.msg.includes("compacting now")));
  assert.ok(
    !notifications.some((n) => n.msg.includes("may be cleaner")),
    "advising a new session while compacting is contradictory",
  );
});

test("runGuardTurn: keeps the fresh-session advice when the compaction is held back", async () => {
  const notifications: { msg: string; type: string }[] = [];

  const fakeCtx = {
    sessionManager: {
      getEntries: () => [{ type: "message", message: { role: "assistant", content: "Done" } }],
      getSessionId: () => "sess-1",
    },
    getContextUsage: () => ({ tokens: 600_000, contextWindow: 1_000_000, percent: 60 }),
    model: { provider: "test", id: "m" },
    cwd: "/tmp",
    compact: () => { throw new Error("must not compact during cooldown"); },
    ui: { notify: (msg: string, type: string) => { notifications.push({ msg, type }); } },
  } as never;

  await runGuardTurn("input", "listo por ahora", fakeCtx, {
    getKey: async () => "key-123",
    lastAdvice: { at: 0, session: "" },
    lastAutoCompact: Date.now(),
    askJevFn: (async () => ({
      model: "jev-latest",
      answers: {
        mid_task: noul(0.1),
        worth_memory: noul(0.1),
        heavy_context: choice("compact-now"),
        session_fresh: choice("new-session"),
      },
      usage: { input_tokens: 10, output_tokens: 5 },
    })) as never,
    traceFn: async () => {},
    saveEngramFn: async () => ({ saved: false, reason: "skipped" }),
  });

  assert.ok(notifications.some((n) => n.msg.includes("may be cleaner")));
});
