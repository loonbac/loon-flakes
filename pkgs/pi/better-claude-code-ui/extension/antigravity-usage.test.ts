import assert from "node:assert/strict";
import test from "node:test";
import { antigravityQuotaIsAvailable, type AntigravityUsageSnapshot } from "./antigravity-usage.ts";

function ready(fiveHour: number, weekly: number | undefined): AntigravityUsageSnapshot {
	return {
		status: "ready",
		remainingFraction: fiveHour,
		weeklyRemainingFraction: weekly,
		resetAt: undefined,
		weeklyResetAt: undefined,
		fetchedAt: Date.now(),
	};
}

test("a restored five-hour and weekly quota invalidates a stale cooldown", () => {
	assert.equal(antigravityQuotaIsAvailable(ready(1, 1)), true);
	assert.equal(antigravityQuotaIsAvailable(ready(0.01, 0.01)), true);
});

test("an exhausted known window keeps the cooldown", () => {
	assert.equal(antigravityQuotaIsAvailable(ready(0, 1)), false);
	assert.equal(antigravityQuotaIsAvailable(ready(1, 0)), false);
});

test("an unavailable read fails safe and an absent weekly window does not invent exhaustion", () => {
	assert.equal(antigravityQuotaIsAvailable({ status: "unavailable" }), false);
	assert.equal(antigravityQuotaIsAvailable(ready(1, undefined)), true);
});
