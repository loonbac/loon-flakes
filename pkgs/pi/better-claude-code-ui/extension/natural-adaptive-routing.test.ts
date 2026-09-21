import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
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
