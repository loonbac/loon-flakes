import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

/**
 * Live snapshot of the OpenCode Go allowance.
 *
 * The Zen usage endpoint reports the percentage already consumed in its
 * rolling (five-hour) and weekly windows.  The sidebar, like the Gemini
 * panel, is phrased as "Restante", so this module converts it once at the
 * boundary and exposes remaining fractions to the renderer.
 *
 * There is deliberately no interval: read once at session start, when the
 * selected model becomes OpenCode Go, and just after an OpenCode Go turn
 * ends.  Those are the only local events that can change this session's
 * quota, without background requests.
 */
export type OpenCodeGoUsageSnapshot =
	| { status: "idle" | "loading" }
	| {
		status: "ready";
		remainingFraction: number;
		weeklyRemainingFraction: number | undefined;
		monthlyRemainingFraction: number | undefined;
		fetchedAt: number;
	}
	| { status: "unavailable" };

type UsageWindow = {
	status?: unknown;
	percent?: unknown;
};

type UsageResponse = {
	usage?: {
		rolling?: UsageWindow;
		weekly?: UsageWindow;
		monthly?: UsageWindow;
	};
};

type LiveUi = {
	invalidateSidebar?: () => void;
	requestRender?: () => void;
};

const PROVIDER = "opencode-go";
const USAGE_ENDPOINT = "https://opencode.ai/zen/go/v1/usage";
const REQUEST_TIMEOUT_MS = 8_000;

let snapshot: OpenCodeGoUsageSnapshot = { status: "idle" };
let inFlight: Promise<void> | undefined;
let inFlightContext: ExtensionContext | undefined;
let refreshGeneration = 0;
let observedModel: string | undefined;

export function openCodeGoUsageSnapshot(): OpenCodeGoUsageSnapshot {
	return snapshot;
}

/** Delayed network work must never use the extension context after /reload. */
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
	} catch {
		// The context was invalidated between the check and UI access.
	}
}

async function apiKeyFromLiveContext(ctx: ExtensionContext): Promise<string | undefined> {
	try {
		return await ctx.modelRegistry.getApiKeyForProvider(PROVIDER);
	} catch {
		return undefined;
	}
}

function remainingFraction(window: UsageWindow | undefined): number | undefined {
	if (window?.status !== "ok" || typeof window.percent !== "number" || !Number.isFinite(window.percent)) return undefined;
	return Math.max(0, Math.min(1, 1 - window.percent / 100));
}

function normaliseUsage(data: unknown): OpenCodeGoUsageSnapshot | undefined {
	if (typeof data !== "object" || data === null) return undefined;
	const usage = (data as UsageResponse).usage;
	if (typeof usage !== "object" || usage === null) return undefined;
	const fiveHourRemaining = remainingFraction(usage.rolling);
	if (fiveHourRemaining === undefined) return undefined;
	return {
		status: "ready",
		remainingFraction: fiveHourRemaining,
		weeklyRemainingFraction: remainingFraction(usage.weekly),
		monthlyRemainingFraction: remainingFraction(usage.monthly),
		fetchedAt: Date.now(),
	};
}

async function fetchUsage(apiKey: string): Promise<OpenCodeGoUsageSnapshot | undefined> {
	try {
		const response = await fetch(USAGE_ENDPOINT, {
			headers: {
				Authorization: `Bearer ${apiKey}`,
				Accept: "application/json",
			},
			signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
		});
		if (!response.ok) return undefined;
		return normaliseUsage(await response.json());
	} catch {
		// This is only a status read. Never log credentials or endpoint payloads.
		return undefined;
	}
}

function refreshUsage(ctx: ExtensionContext): void {
	if (inFlight && inFlightContext === ctx) return;
	const generation = ++refreshGeneration;
	const task = (async () => {
		const apiKey = await apiKeyFromLiveContext(ctx);
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

export function registerOpenCodeGoUsage(pi: ExtensionAPI): void {
	pi.on("session_start", (_event, ctx) => {
		if (!ctx.hasUI) return;
		retireSession();
		observedModel = activeModelKey(ctx);
		// One initial read for a signed-in Go subscription, not a polling loop.
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
