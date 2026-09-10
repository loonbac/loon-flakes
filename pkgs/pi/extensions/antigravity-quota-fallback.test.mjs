import assert from "node:assert/strict";
import test from "node:test";

import {
  AGENT_FALLBACK_CHAINS,
  FALLBACK_CHAIN,
  PRIMARY_ANTIGRAVITY_PROVIDER,
  SECONDARY_ANTIGRAVITY_PROVIDER,
  appendedSystemPrompts,
  cooldownDeadline,
  fallbackChainForAgent,
  fallbackIndex,
  isQuotaExhaustion,
  matchGentleAgentName,
  parseAgentDefinitionIdentity,
  parseWaitDurationMs,
} from "./antigravity-quota-fallback.ts";

test("orders Experiential DeepSeek before OpenCode Muse", () => {
  assert.equal(PRIMARY_ANTIGRAVITY_PROVIDER, "antigravity");
  assert.equal(SECONDARY_ANTIGRAVITY_PROVIDER, "antigravity-alt");
  assert.deepEqual(
    FALLBACK_CHAIN.map(({ provider, model }) => `${provider}/${model}`),
    [
      "explabs/deepseek-v4.1-flash",
      "opencode-go/muse-spark-1.3-contributor",
    ],
  );
  assert.equal(fallbackIndex("explabs", "deepseek-v4.1-flash"), 0);
  assert.equal(fallbackIndex("opencode-go", "muse-spark-1.3-contributor"), 1);
  assert.equal(fallbackIndex("antigravity", "gemini-3.8-flash"), -1);
  assert.equal(fallbackIndex("antigravity-alt", "gemini-3.8-flash"), -1);
});

test("assigns exactly two ordered fallbacks and the requested effort to every target agent", () => {
  const route = (provider, model, thinking) => `${provider}/${model}:${thinking}`;
  const deepseek = route("explabs", "deepseek-v4.1-flash", "high");
  const museXHigh = route("opencode-go", "muse-spark-1.3-contributor", "xhigh");
  const museMax = route("opencode-go", "muse-spark-1.3-contributor", "max");
  const expected = {
    "gentle-ai-explore": [deepseek, museXHigh],
    "gentle-ai-worker": [museMax, deepseek],
    "jd-fix-agent": [deepseek, museMax],
    "sdd-explore": [deepseek, museXHigh],
    "sdd-spec": [museXHigh, deepseek],
    "sdd-tasks": [deepseek, museXHigh],
    "sdd-apply": [museMax, deepseek],
    "sdd-onboard": [deepseek, museXHigh],
  };

  assert.deepEqual(Object.keys(AGENT_FALLBACK_CHAINS).sort(), Object.keys(expected).sort());
  for (const [agent, routes] of Object.entries(expected)) {
    assert.deepEqual(
      fallbackChainForAgent(agent).map(({ provider, model, thinking }) => route(provider, model, thinking)),
      routes,
    );
    assert.equal(fallbackChainForAgent(agent).length, 2);
  }
  assert.equal(fallbackChainForAgent("unknown-agent"), FALLBACK_CHAIN);
});

test("identifies a Gentle child from its exact appended agent instructions", () => {
  const definition = parseAgentDefinitionIdentity(
    "---\nname: sdd-spec\ndescription: writes specs\n---\nWrite delta specs carefully.\n",
    "fallback-name",
  );
  assert.deepEqual(definition, {
    name: "sdd-spec",
    instructions: "Write delta specs carefully.",
  });

  const prompts = appendedSystemPrompts([
    "pi",
    "--append-system-prompt=shared parent instructions",
    "--append-system-prompt",
    "Write delta specs carefully.",
  ]);
  assert.deepEqual(prompts, ["shared parent instructions", "Write delta specs carefully."]);
  assert.equal(matchGentleAgentName(prompts, [definition]), "sdd-spec");
  assert.equal(matchGentleAgentName(["different instructions"], [definition]), undefined);
});

test("recognizes the Antigravity quota error and its compact reset duration", () => {
  const error = "Quota reached. Please wait 22h46m49s. Next: switch models or try again after reset.";
  assert.equal(isQuotaExhaustion(error), true);
  assert.equal(parseWaitDurationMs(error), ((22 * 60 + 46) * 60 + 49) * 1000);
});

test("supports day and minute reset durations", () => {
  assert.equal(parseWaitDurationMs("RESOURCE_EXHAUSTED; retry after 1d 2h 3m"), 93_780_000);
});

test("does not classify unrelated provider failures as quota exhaustion", () => {
  assert.equal(isQuotaExhaustion("400 status code (no body)"), false);
  assert.equal(isQuotaExhaustion("Request timed out"), false);
});

test("uses a bounded default cooldown when the quota error has no duration", () => {
  const now = 1_000_000;
  assert.equal(cooldownDeadline("Quota exceeded", now), now + 24 * 60 * 60 * 1000 + 2 * 60 * 1000);
});
