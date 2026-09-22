import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  adaptivePromptSystemPrompt,
  adaptiveRecoveryRouteAllowed,
  legacyFallbackMayPreempt,
  prepareAdaptiveApplication,
  recoveryLineage,
  routeDiffersFromConfiguredGentleDefault,
  routeMatches,
  registerAdaptiveCommands,
  validAdaptiveDecision,
  type AdaptiveDecision,
} from "./natural-adaptive-routing.ts";

const decision: AdaptiveDecision = {
  kind: "ADAPTIVE_ASSIGNMENT", decisionId: "D-1", reason: "fixture", mode: "ACTIVE_GUARDED",
  role: "gentle-ai-worker", taskClass: "small implementation", risk: "LOW",
  staticRoute: { provider: "openai-codex", model: "gpt-5.6-terra", requestedEffort: "high", effectiveEffort: "high" },
  requestedAdaptiveRoute: { provider: "opencode-go", model: "glm-5.3-flash", requestedEffort: "high", effectiveEffort: "high" },
  exploration: false, compiledPrompt: "## Goal\n- bounded fixture", promptProfileId: "EXPLICIT",
  promptProfileVersion: "prompt-profile-v1", promptCompilerVersion: "prompt-compiler-v1",
  canonicalContractHash: "contract", compiledPromptHash: "compiled", promptExecutionStatus: "ACTUAL", routingLatencyMs: 2,
};

test("actual custom plugin path applies one adaptive primary before recovery", () => {
  const applied = prepareAdaptiveApplication("gentle-ai-worker", "STATIC SYSTEM", decision);
  assert.deepEqual(applied.route, decision.requestedAdaptiveRoute);
  assert.match(applied.systemPrompt, /^STATIC SYSTEM/u);
  assert.match(applied.systemPrompt, /Adaptive work-unit contract/u);
  assert.equal(applied.recoveryInvoked, false);
  assert.equal(legacyFallbackMayPreempt(true), false);
});

test("provider failure creates a distinct recovery attempt", () => {
  const fallback = { provider: "openai-codex", model: "gpt-5.6-terra", requestedEffort: "high" as const, effectiveEffort: "high" as const };
  const lineage = recoveryLineage(decision.requestedAdaptiveRoute!, fallback, "provider unavailable");
  assert.equal(lineage.primaryAttempt.attemptIndex, 0);
  assert.equal(lineage.fallbackAttempt.attemptIndex, 1);
  assert.notDeepEqual(lineage.primaryAttempt.route, lineage.fallbackAttempt.route);
});

test("requested and observed route include effort", () => {
  assert.equal(routeMatches(decision.requestedAdaptiveRoute!, { ...decision.requestedAdaptiveRoute! }), true);
  assert.equal(routeMatches(decision.requestedAdaptiveRoute!, { ...decision.requestedAdaptiveRoute!, effectiveEffort: "low" }), false);
});

test("Opus generic and closed Command Code routes are rejected", () => {
  assert.equal(validAdaptiveDecision({ ...decision, requestedAdaptiveRoute: { provider: "antigravity", model: "claude-opus-4-6", requestedEffort: "high", effectiveEffort: "high" } }, "gentle-ai-worker"), false);
  assert.equal(validAdaptiveDecision({ ...decision, requestedAdaptiveRoute: { provider: "commandcode", model: "gpt-5.6-sol", requestedEffort: "high", effectiveEffort: "high" } }, "gentle-ai-worker"), false);
  assert.equal(adaptiveRecoveryRouteAllowed({ provider: "antigravity", model: "claude-opus-4-6" }, "gentle-ai-worker"), false);
  assert.equal(adaptiveRecoveryRouteAllowed({ provider: "antigravity", model: "claude-opus-4-6" }, "jd-judge-b"), true);
});

test("transactionally onboarded active route passes existing host guard", () => {
  const previous = process.env.NATURAL_ROUTER_STATE_DIR;
  const directory = mkdtempSync(join(tmpdir(), "adaptive-onboard-"));
  try {
    process.env.NATURAL_ROUTER_STATE_DIR = directory;
    const route = { provider: "fixture", model: "test-model", requestedEffort: "high" as const, effectiveEffort: "high" as const };
    assert.equal(validAdaptiveDecision({ ...decision, requestedAdaptiveRoute: route }, "gentle-ai-worker"), false);
    writeFileSync(join(directory, "model-catalog.json"), JSON.stringify({ schemaVersion: "model-catalog-v1", models: { "fixture/test-model": { status: "ACTIVE" } } }));
    assert.equal(validAdaptiveDecision({ ...decision, requestedAdaptiveRoute: route }, "gentle-ai-worker"), true);
    assert.equal(adaptiveRecoveryRouteAllowed(route, "gentle-ai-worker"), true);
  } finally {
    if (previous === undefined) delete process.env.NATURAL_ROUTER_STATE_DIR;
    else process.env.NATURAL_ROUTER_STATE_DIR = previous;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("/adaptive model-add fixture/test-model --dry-run --offline reaches the existing router command", async () => {
  const previousState = process.env.NATURAL_ROUTER_STATE_DIR;
  const directory = mkdtempSync(join(tmpdir(), "adaptive-command-"));
  let handler: ((args: string, context: unknown) => Promise<void>) | undefined;
  const notifications: string[] = [];
  try {
    process.env.NATURAL_ROUTER_STATE_DIR = directory;
    registerAdaptiveCommands({ registerCommand: (_name: string, command: { handler: (args: string, context: unknown) => Promise<void> }) => { handler = command.handler; } } as unknown as Parameters<typeof registerAdaptiveCommands>[0]);
    assert.ok(handler);
    await handler("model-add fixture/test-model --dry-run --offline", {
      modelRegistry: { getAvailable: () => [{ provider: "fixture", id: "test-model", name: "Fixture", reasoning: false, contextWindow: 32768, input: ["text"], supportsTools: true }] },
      ui: { notify: (message: string) => notifications.push(message) },
    });
    assert.match(notifications[0] ?? "", /MODEL ONBOARDING DRY RUN/u);
    assert.match(notifications[0] ?? "", /READY_SHADOW_ONLY/u);
  } finally {
    if (previousState === undefined) delete process.env.NATURAL_ROUTER_STATE_DIR;
    else process.env.NATURAL_ROUTER_STATE_DIR = previousState;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("compiled contract is appended without rewriting the existing system prompt", () => {
  assert.equal(adaptivePromptSystemPrompt("ORIGINAL", { ...decision, compiledPrompt: undefined }), "ORIGINAL");
  assert.match(adaptivePromptSystemPrompt("ORIGINAL", decision), /^ORIGINAL/u);
});

test("a current work-unit route that differs from configured Gentle default is user-pinned", () => {
  const previous = process.env.GENTLE_PI_CONFIG_HOME;
  const directory = mkdtempSync(join(tmpdir(), "gentle-profile-"));
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, "profiles.json"), JSON.stringify({
    active: "current", profiles: { current: { "gentle-ai-worker": { model: "openai-codex/gpt-5.6-terra", thinking: "high" } } },
  }));
  process.env.GENTLE_PI_CONFIG_HOME = directory;
  assert.equal(routeDiffersFromConfiguredGentleDefault("gentle-ai-worker", decision.staticRoute), false);
  assert.equal(routeDiffersFromConfiguredGentleDefault("gentle-ai-worker", decision.requestedAdaptiveRoute!), true);
  if (previous === undefined) delete process.env.GENTLE_PI_CONFIG_HOME;
  else process.env.GENTLE_PI_CONFIG_HOME = previous;
});
