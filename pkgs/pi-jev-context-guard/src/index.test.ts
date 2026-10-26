import { test } from "node:test";
import assert from "node:assert/strict";
import {
  decide,
  extractText,
  recentMessagesFrom,
  buildCompactionInstructions,
  QUESTIONS,
  askJev,
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
