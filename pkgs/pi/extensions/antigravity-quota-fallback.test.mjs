import assert from "node:assert/strict";
import test from "node:test";

import {
  cooldownDeadline,
  isQuotaExhaustion,
  parseWaitDurationMs,
} from "./antigravity-quota-fallback.ts";

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
