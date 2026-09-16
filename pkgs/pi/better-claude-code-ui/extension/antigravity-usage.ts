import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

/**
 * Small, live snapshots of Antigravity A and B's shared quota pools.
 *
 * This intentionally has no timer. A quota read happens once when an
 * interactive session begins, then again only after Pi has received a response
 * from either account (or when a model for that account becomes active). That
 * makes the value
 * fresh at the only moments it can change because of this Pi session, without
 * background polling or a persistent credential cache.
 */
export type AntigravityUsageSnapshot =
	| { status: "idle" | "loading" }
	| {
		status: "ready";
		remainingFraction: number;
		weeklyRemainingFraction: number | undefined;
		resetAt: number | undefined;
		weeklyResetAt: number | undefined;
		fetchedAt: number;
	}
	| { status: "unavailable" };

type ProviderId = "antigravity" | "antigravity-alt";

type AccountState = {
	provider: ProviderId;
	snapshot: AntigravityUsageSnapshot;
	inFlight: Promise<void> | undefined;
	inFlightContext: ExtensionContext | undefined;
	refreshGeneration: number;
	observedModel: string | undefined;
};

const accountA: AccountState = {
	provider: "antigravity",
	snapshot: { status: "idle" },
	inFlight: undefined,
	inFlightContext: undefined,
	refreshGeneration: 0,
	observedModel: undefined,
};

const accountB: AccountState = {
	provider: "antigravity-alt",
	snapshot: { status: "idle" },
	inFlight: undefined,
	inFlightContext: undefined,
	refreshGeneration: 0,
	observedModel: undefined,
};

const accounts = [accountA, accountB] as const;

const ENDPOINTS = [
	"https://daily-cloudcode-pa.googleapis.com",
	"https://daily-cloudcode-pa.sandbox.googleapis.com",
	"https://cloudcode-pa.googleapis.com",
] as const;
const QUOTA_PATH = "/v1internal:retrieveUserQuotaSummary";
const USER_AGENT = "antigravity/cli/1.1.23 (aidev_client; os_type=linux; arch=amd64; cl=974125021; auth_method=consumer)";
const REQUEST_TIMEOUT_MS = 8_000;

type QuotaBucket = {
	displayName?: unknown;
	window?: unknown;
	remainingFraction?: unknown;
	resetTime?: unknown;
};

type QuotaGroup = {
	displayName?: unknown;
	buckets?: unknown;
};

type QuotaSummary = {
	groups?: unknown;
};

type LiveUi = {
	invalidateSidebar?: () => void;
	requestRender?: () => void;
};

export function antigravityAUsageSnapshot(): AntigravityUsageSnapshot {
	return accountA.snapshot;
}

export function antigravityBUsageSnapshot(): AntigravityUsageSnapshot {
	return accountB.snapshot;
}

function contextIsCurrent(ctx: ExtensionContext, account: AccountState, generation: number): boolean {
	if (generation !== account.refreshGeneration) return false;
	try {
		return ctx.hasUI;
	} catch {
		return false;
	}
}

function redraw(ctx: ExtensionContext, account: AccountState, generation: number): void {
	if (!contextIsCurrent(ctx, account, generation)) return;
	try {
		const ui = ctx.ui as unknown as LiveUi;
		// invalidateSidebar is supplied narrowly by host-patches.ts. requestRender
		// keeps this helper harmless when Better CC's host bridge is unavailable.
		ui.invalidateSidebar?.();
		ui.requestRender?.();
	} catch {
		// A reload/session switch invalidated ctx between the guard and access.
	}
}

async function apiKeyFromLiveContext(ctx: ExtensionContext, provider: ProviderId): Promise<string | undefined> {
	try {
		return await ctx.modelRegistry.getApiKeyForProvider(provider);
	} catch {
		return undefined;
	}
}

function tokenFromApiKey(apiKey: string | undefined): string | undefined {
	if (!apiKey) return undefined;
	try {
		const parsed = JSON.parse(apiKey) as { token?: unknown };
		return typeof parsed.token === "string" && parsed.token.length > 0 ? parsed.token : undefined;
	} catch {
		return undefined;
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function isFiveHourBucket(bucket: QuotaBucket): boolean {
	const label = typeof bucket.displayName === "string" ? bucket.displayName : "";
	const window = typeof bucket.window === "string" ? bucket.window : "";
	return /(?:five|5)\s*(?:hour|h)\b/i.test(`${label} ${window}`);
}

function isWeeklyBucket(bucket: QuotaBucket): boolean {
	const label = typeof bucket.displayName === "string" ? bucket.displayName : "";
	const window = typeof bucket.window === "string" ? bucket.window : "";
	return /\b(?:weekly|week|7d|seven\s*day)\b/i.test(`${label} ${window}`);
}

function usableBucket(group: QuotaGroup): QuotaBucket | undefined {
	if (!Array.isArray(group.buckets)) return undefined;
	return group.buckets.find((bucket): bucket is QuotaBucket => isRecord(bucket) && isFiveHourBucket(bucket));
}

function findQuotaBuckets(data: unknown): { fiveHour: QuotaBucket; weekly: QuotaBucket | undefined } | undefined {
	if (!isRecord(data)) return undefined;
	const rawGroups = (data as QuotaSummary).groups;
	if (!Array.isArray(rawGroups)) return undefined;
	const groups = rawGroups.filter(isRecord) as QuotaGroup[];
	// Account A's Gemini pool is the first shared five-hour quota shown by
	// /antigravity.usage. Prefer it explicitly; retain a safe generic fallback
	// in case Google renames that section.
	for (const group of groups) {
		if (/gemini/i.test(typeof group.displayName === "string" ? group.displayName : "")) {
			const fiveHour = usableBucket(group);
			if (fiveHour) {
				const weekly = Array.isArray(group.buckets)
					? group.buckets.find((bucket): bucket is QuotaBucket => isRecord(bucket) && isWeeklyBucket(bucket))
					: undefined;
				return { fiveHour, weekly };
			}
		}
	}
	for (const group of groups) {
		const fiveHour = usableBucket(group);
		if (!fiveHour) continue;
		const weekly = Array.isArray(group.buckets)
			? group.buckets.find((bucket): bucket is QuotaBucket => isRecord(bucket) && isWeeklyBucket(bucket))
			: undefined;
		return { fiveHour, weekly };
	}
	return undefined;
}

function normaliseFraction(bucket: QuotaBucket | undefined): number | undefined {
	if (!bucket || typeof bucket.remainingFraction !== "number" || !Number.isFinite(bucket.remainingFraction)) return undefined;
	return Math.max(0, Math.min(1, bucket.remainingFraction));
}

function normaliseResetAt(bucket: QuotaBucket | undefined): number | undefined {
	if (!bucket || typeof bucket.resetTime !== "string") return undefined;
	const timestamp = Date.parse(bucket.resetTime);
	return Number.isFinite(timestamp) ? timestamp : undefined;
}

function normaliseBuckets(buckets: { fiveHour: QuotaBucket; weekly: QuotaBucket | undefined }): AntigravityUsageSnapshot | undefined {
	const remainingFraction = normaliseFraction(buckets.fiveHour);
	if (remainingFraction === undefined) return undefined;
	return {
		status: "ready",
		remainingFraction,
		weeklyRemainingFraction: normaliseFraction(buckets.weekly),
		resetAt: normaliseResetAt(buckets.fiveHour),
		weeklyResetAt: normaliseResetAt(buckets.weekly),
		fetchedAt: Date.now(),
	};
}

async function fetchQuota(token: string): Promise<AntigravityUsageSnapshot | undefined> {
	for (const endpoint of ENDPOINTS) {
		try {
			const response = await fetch(`${endpoint}${QUOTA_PATH}`, {
				method: "POST",
				headers: {
					Authorization: `Bearer ${token}`,
					"Content-Type": "application/json",
					Accept: "application/json",
					"User-Agent": USER_AGENT,
				},
				body: "{}",
				signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
			});
			if (!response.ok) continue;
			const buckets = findQuotaBuckets(await response.json());
			const usage = buckets && normaliseBuckets(buckets);
			if (usage) return usage;
		} catch {
			// Try the provider's next official endpoint. No credential or response
			// body is logged from this status-only best-effort request.
		}
	}
	return undefined;
}

function refreshAccountUsage(ctx: ExtensionContext, account: AccountState): void {
	if (account.inFlight && account.inFlightContext === ctx) return;
	const generation = ++account.refreshGeneration;
	const task = (async () => {
		const token = tokenFromApiKey(await apiKeyFromLiveContext(ctx, account.provider));
		if (!contextIsCurrent(ctx, account, generation)) return;
		if (!token) {
			account.snapshot = { status: "unavailable" };
			redraw(ctx, account, generation);
			return;
		}

		account.snapshot = { status: "loading" };
		redraw(ctx, account, generation);
		const usage = await fetchQuota(token);
		if (!contextIsCurrent(ctx, account, generation)) return;
		account.snapshot = usage ?? { status: "unavailable" };
		redraw(ctx, account, generation);
	})();
	account.inFlight = task;
	account.inFlightContext = ctx;
	void task.then(
		() => {
			if (account.inFlight === task) {
				account.inFlight = undefined;
				account.inFlightContext = undefined;
			}
		},
		() => {
			if (account.inFlight === task) {
				account.inFlight = undefined;
				account.inFlightContext = undefined;
			}
		},
	);
}

function modelKeyForAccount(ctx: ExtensionContext, account: AccountState): string | undefined {
	return ctx.model?.provider === account.provider && ctx.model
		? `${ctx.model.provider}/${ctx.model.id}`
		: undefined;
}

function activeAccount(ctx: ExtensionContext): AccountState | undefined {
	return accounts.find((account) => ctx.model?.provider === account.provider);
}

function retireSession(): void {
	for (const account of accounts) {
		account.refreshGeneration += 1;
		account.inFlight = undefined;
		account.inFlightContext = undefined;
		account.observedModel = undefined;
		account.snapshot = { status: "idle" };
	}
}

export function registerAntigravityUsage(pi: ExtensionAPI): void {
	pi.on("session_start", (_event, ctx) => {
		if (!ctx.hasUI) return;
		retireSession();
		for (const account of accounts) {
			account.observedModel = modelKeyForAccount(ctx, account);
			// One startup read per signed-in account; there is no interval/poll.
			refreshAccountUsage(ctx, account);
		}
	});

	pi.on("session_shutdown", () => retireSession());

	// Switching account is an explicit event, so it merits a one-off refresh
	// before the selected account produces its first answer.
	pi.on("session_info_changed", (_event, ctx) => {
		if (!ctx.hasUI) return;
		for (const account of accounts) {
			const modelKey = modelKeyForAccount(ctx, account);
			if (!modelKey) {
				account.observedModel = undefined;
				continue;
			}
			if (modelKey === account.observedModel) continue;
			account.observedModel = modelKey;
			refreshAccountUsage(ctx, account);
		}
	});

	// This is the normal steady-state path: one request after a completed
	// turn for that account, never an interval in the background. Waiting for
	// agent_end means the backend has had time to account for the whole stream.
	pi.on("agent_end", (_event, ctx) => {
		const account = activeAccount(ctx);
		if (ctx.hasUI && account) refreshAccountUsage(ctx, account);
	});
}
