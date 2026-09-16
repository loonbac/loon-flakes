import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Live Command Code quota snapshot.
 *
 * Command Code exposes exact 5-hour and weekly credit windows. Its third
 * pool is billing-period credit remaining (monthly + any purchased/free
 * credit), so the renderer calls it "créditos" rather than incorrectly
 * presenting it as a subscription-only monthly limit.
 *
 * There is no polling: one read at startup, once on selection of a Command
 * Code model, and once after a Command Code turn completes.
 */
export type CommandCodeUsageSnapshot =
	| { status: "idle" | "loading" }
	| {
		status: "ready";
		remainingFraction: number;
		weeklyRemainingFraction: number | undefined;
		creditRemainingFraction: number | undefined;
		fetchedAt: number;
	}
	| { status: "unavailable" };

type WindowLimit = {
	used?: unknown;
	cap?: unknown;
};

type WhoAmIResponse = {
	org?: { id?: unknown };
};

type CreditsResponse = {
	credits?: {
		monthlyCredits?: unknown;
		purchasedCredits?: unknown;
		freeCredits?: unknown;
	};
	windowLimits?: {
		fiveHour?: WindowLimit;
		weekly?: WindowLimit;
	};
};

type SubscriptionResponse = {
	data?: { currentPeriodStart?: unknown };
};

type UsageSummaryResponse = {
	totalCost?: unknown;
};

type LiveUi = {
	invalidateSidebar?: () => void;
	requestRender?: () => void;
};

const PROVIDER = "commandcode";
// host-patches.ts publishes this narrow bridge when Gentle mounts its rail.
// Calling it bumps Gentle's *terminal-owned* cache revision as well as asking
// Pi to redraw.  The ordinary extension UI context only knows about a regular
// render, which is not sufficient for a memoized sidebar card.
const GENTLE_SIDEBAR_REDRAW = Symbol.for("better-cc-ui:wallpaper-redraw");
// Match Command Code's own quota command: it is four dependent, one-off
// requests (identity → credits/subscription → period summary), not a poll.
const REQUEST_TIMEOUT_MS = 15_000;
const PLACEHOLDER_KEYS = new Set([
	"$COMMAND_CODE_API_KEY",
	"COMMAND_CODE_API_KEY",
	"$COMMANDCODE_API_KEY",
	"COMMANDCODE_API_KEY",
]);

function commandCodeApiBase(value: string): string | undefined {
	try {
		const url = new URL(value);
		const loopback = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
		if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) return undefined;
		if (url.username || url.password || url.search || url.hash) return undefined;
		url.pathname = url.pathname.replace(/\/provider\/v1\/?$/, "").replace(/\/+$/, "");
		return url.toString().replace(/\/$/, "");
	} catch {
		return undefined;
	}
}

const apiBase = commandCodeApiBase(process.env.COMMANDCODE_API_BASE ?? "https://api.commandcode.ai/provider/v1");

let snapshot: CommandCodeUsageSnapshot = { status: "idle" };
let inFlight: Promise<void> | undefined;
let inFlightContext: ExtensionContext | undefined;
let refreshGeneration = 0;
let observedModel: string | undefined;

export function commandCodeUsageSnapshot(): CommandCodeUsageSnapshot {
	return snapshot;
}

/**
 * A quota request can outlive /reload, newSession, or switchSession. Pi
 * deliberately invalidates that old context, so every delayed UI touch must
 * be both current and exception-safe. A stale result is simply irrelevant.
 */
function contextIsCurrent(ctx: ExtensionContext, generation: number): boolean {
	if (generation !== refreshGeneration) return false;
	try {
		return ctx.hasUI;
	} catch {
		return false;
	}
}

function redraw(ctx: ExtensionContext, generation: number): void {
	if (!contextIsCurrent(ctx, generation)) return;
	try {
		const ui = ctx.ui as unknown as LiveUi;
		ui.invalidateSidebar?.();
		ui.requestRender?.();
		const redrawGentleSidebar = (globalThis as unknown as Record<symbol, unknown>)[GENTLE_SIDEBAR_REDRAW];
		if (typeof redrawGentleSidebar === "function") redrawGentleSidebar();
	} catch {
		// Pi replaced this session between the check and the render. Never let a
		// cosmetic quota refresh terminate the interactive process.
	}
}

async function apiKeyFromLiveContext(ctx: ExtensionContext): Promise<string | undefined> {
	try {
		return await ctx.modelRegistry.getApiKeyForProvider(PROVIDER);
	} catch {
		return undefined;
	}
}

function nonnegativeNumber(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function remainingWindowFraction(window: WindowLimit | undefined): number | undefined {
	const used = nonnegativeNumber(window?.used);
	const cap = nonnegativeNumber(window?.cap);
	if (used === undefined || cap === undefined || cap <= 0) return undefined;
	return Math.max(0, Math.min(1, 1 - used / cap));
}

function creditRemainingFraction(credits: CreditsResponse["credits"], summary: UsageSummaryResponse | undefined): number | undefined {
	const values = [
		nonnegativeNumber(credits?.monthlyCredits),
		nonnegativeNumber(credits?.purchasedCredits),
		nonnegativeNumber(credits?.freeCredits),
	];
	if (!values.some((value) => value !== undefined)) return undefined;
	const remaining = values.reduce<number>((sum, value) => sum + (value ?? 0), 0);
	const usedThisPeriod = nonnegativeNumber(summary?.totalCost);
	if (usedThisPeriod === undefined) return undefined;
	const pool = remaining + usedThisPeriod;
	return pool > 0 ? Math.max(0, Math.min(1, remaining / pool)) : undefined;
}

function orgQuery(orgId: unknown): string {
	return typeof orgId === "string" && orgId.length > 0 ? `?orgId=${encodeURIComponent(orgId)}` : "";
}

function configuredApiKey(value: string | undefined): string | undefined {
	const key = value?.trim();
	return key && !PLACEHOLDER_KEYS.has(key) ? key : undefined;
}

function valueFromCredential(value: unknown): string | undefined {
	if (typeof value === "string") return configuredApiKey(value);
	if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
	const credential = value as { access?: unknown; key?: unknown };
	return typeof credential.access === "string" ? configuredApiKey(credential.access)
		: typeof credential.key === "string" ? configuredApiKey(credential.key)
			: undefined;
}

/** Pi stores Command Code browser login as a JSON OAuth credential. */
function apiKeyFromRegistry(value: string | undefined): string | undefined {
	if (!value) return undefined;
	try {
		const credential = JSON.parse(value) as unknown;
		const key = valueFromCredential(credential);
		if (key) return key;
	} catch {
		// API-key logins are already bare strings.
	}
	return configuredApiKey(value);
}

/** Same documented credential fallback as pi-commandcode-provider itself. */
function commandCodeApiKeyFromAuthFile(): string | undefined {
	for (const file of [
		join(homedir(), ".commandcode", "auth.json"),
		join(homedir(), ".pi", "agent", "auth.json"),
		join(homedir(), ".omp", "agent", "auth.json"),
	]) {
		try {
			if (!existsSync(file)) continue;
			const auth = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
			// A Pi auth file can carry an unrelated legacy `apiKey`. Prefer the
			// provider-scoped credential so another service's key is never sent to
			// Command Code; the generic field remains only as legacy fallback.
			const key = valueFromCredential(auth.commandcode)
				?? valueFromCredential(auth["command-code"])
				?? configuredApiKey(typeof auth.apiKey === "string" ? auth.apiKey : undefined);
			if (key) return key;
		} catch {
			// Preserve the provider's behavior: unreadable or malformed auth files
			// simply mean no local credential fallback.
		}
	}
	return undefined;
}

function requestHeaders(apiKey: string): HeadersInit {
	return {
		Accept: "application/json",
		Authorization: `Bearer ${apiKey}`,
		// Match the provider's documented zero-data-retention option whenever it
		// is already active for the chat transport.
		...((process.env.CMD_ZDR === "1" || process.env.COMMANDCODE_ZDR === "1") ? { "x-cmd-zdr": "1" } : {}),
	};
}

async function fetchUsage(apiKey: string): Promise<CommandCodeUsageSnapshot | undefined> {
	try {
		if (!apiBase) return undefined;
		const signal = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
		const headers = requestHeaders(apiKey);
		const whoamiResponse = await fetch(`${apiBase}/alpha/whoami`, { headers, signal, redirect: "error" });
		if (!whoamiResponse.ok) return undefined;
		const whoami = await whoamiResponse.json() as WhoAmIResponse;
		const query = orgQuery(whoami.org?.id);

		const [creditsResponse, subscriptionResponse] = await Promise.all([
			fetch(`${apiBase}/alpha/billing/credits${query}`, { headers, signal, redirect: "error" }),
			fetch(`${apiBase}/alpha/billing/subscriptions${query}`, { headers, signal, redirect: "error" }),
		]);
		if (!creditsResponse.ok || !subscriptionResponse.ok) return undefined;
		const credits = await creditsResponse.json() as CreditsResponse;
		const subscription = await subscriptionResponse.json() as SubscriptionResponse;
		const periodStart = subscription.data?.currentPeriodStart;
		const usageQuery = `${query ? `${query}&` : "?"}${typeof periodStart === "string" && periodStart.length > 0 ? `since=${encodeURIComponent(periodStart)}` : ""}`;
		const summaryResponse = await fetch(`${apiBase}/alpha/usage/summary${usageQuery}`, { headers, signal, redirect: "error" });
		if (!summaryResponse.ok) return undefined;
		const summary = await summaryResponse.json() as UsageSummaryResponse;

		const fiveHourRemaining = remainingWindowFraction(credits.windowLimits?.fiveHour);
		if (fiveHourRemaining === undefined) return undefined;
		return {
			status: "ready",
			remainingFraction: fiveHourRemaining,
			weeklyRemainingFraction: remainingWindowFraction(credits.windowLimits?.weekly),
			creditRemainingFraction: creditRemainingFraction(credits.credits, summary),
			fetchedAt: Date.now(),
		};
	} catch {
		// A status-only read: credentials and response bodies are never logged.
		return undefined;
	}
}

function refreshUsage(ctx: ExtensionContext): void {
	if (inFlight && inFlightContext === ctx) return;
	const generation = ++refreshGeneration;
	const task = (async () => {
		// Prefer the provider-scoped record. Pi may surface a generic registry
		// fallback before it has resolved the custom provider's OAuth object.
		const apiKey = commandCodeApiKeyFromAuthFile()
			?? apiKeyFromRegistry(await apiKeyFromLiveContext(ctx));
		if (!contextIsCurrent(ctx, generation)) return;
		if (!apiKey) {
			snapshot = { status: "unavailable" };
			redraw(ctx, generation);
			return;
		}

		snapshot = { status: "loading" };
		redraw(ctx, generation);
		const result = await fetchUsage(apiKey);
		if (!contextIsCurrent(ctx, generation)) return;
		snapshot = result ?? { status: "unavailable" };
		redraw(ctx, generation);
	})();
	inFlight = task;
	inFlightContext = ctx;
	void task.then(
		() => {
			if (inFlight === task) {
				inFlight = undefined;
				inFlightContext = undefined;
			}
		},
		() => {
			if (inFlight === task) {
				inFlight = undefined;
				inFlightContext = undefined;
			}
		},
	);
}

function activeModelKey(ctx: ExtensionContext): string | undefined {
	return ctx.model?.provider === PROVIDER && ctx.model
		? `${ctx.model.provider}/${ctx.model.id}`
		: undefined;
}

function retireSession(): void {
	refreshGeneration += 1;
	inFlight = undefined;
	inFlightContext = undefined;
	observedModel = undefined;
	snapshot = { status: "idle" };
}

export function registerCommandCodeUsage(pi: ExtensionAPI): void {
	pi.on("session_start", (_event, ctx) => {
		if (!ctx.hasUI) return;
		retireSession();
		observedModel = activeModelKey(ctx);
		refreshUsage(ctx);
	});

	pi.on("session_shutdown", () => retireSession());

	pi.on("session_info_changed", (_event, ctx) => {
		if (!ctx.hasUI) return;
		const modelKey = activeModelKey(ctx);
		if (!modelKey) {
			observedModel = undefined;
			return;
		}
		if (modelKey === observedModel) return;
		observedModel = modelKey;
		refreshUsage(ctx);
	});

	pi.on("agent_end", (_event, ctx) => {
		if (ctx.hasUI && ctx.model?.provider === PROVIDER) refreshUsage(ctx);
	});
}
