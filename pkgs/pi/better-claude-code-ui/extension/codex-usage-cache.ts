import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Last known Codex weekly utilization. Gentle fetches the live value and the
 * host patch observes it; this tiny cache prevents the rail from reverting to
 * a startup placeholder before that asynchronous request completes. */
export type CodexUsageSnapshot =
	| { status: "idle" }
	| { status: "ready"; usedPercent: number; fetchedAt: number };

interface CacheFile {
	version: 1;
	usedPercent: number;
	fetchedAt: number;
}

function cachePath(): string {
	const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
	return join(agentDir, "state", "loon-codex-weekly-usage.json");
}

function validPercent(value: unknown): value is number {
	return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100;
}

function loadSnapshot(): CodexUsageSnapshot {
	try {
		const parsed = JSON.parse(readFileSync(cachePath(), "utf8")) as Partial<CacheFile>;
		if (parsed.version !== 1 || !validPercent(parsed.usedPercent) || typeof parsed.fetchedAt !== "number") return { status: "idle" };
		return { status: "ready", usedPercent: parsed.usedPercent, fetchedAt: parsed.fetchedAt };
	} catch {
		return { status: "idle" };
	}
}

let snapshot: CodexUsageSnapshot = loadSnapshot();
let persistQueued = false;

export function codexUsageSnapshot(): CodexUsageSnapshot {
	return snapshot;
}

function persist(): void {
	if (snapshot.status !== "ready") return;
	try {
		const target = cachePath();
		mkdirSync(dirname(target), { recursive: true });
		const temporary = `${target}.tmp-${process.pid}`;
		const data: CacheFile = { version: 1, usedPercent: snapshot.usedPercent, fetchedAt: snapshot.fetchedAt };
		writeFileSync(temporary, `${JSON.stringify(data)}\n`, { mode: 0o600 });
		renameSync(temporary, target);
	} catch {
		// Usage display is best-effort and must never interfere with the session.
	}
}

/** Called from the rendered Gentle value and from Codex response headers.
 * Writes are change-driven and coalesced; there is no polling or per-frame IO. */
export function observeCodexUsage(usedPercent: number, fetchedAt = Date.now()): void {
	if (!validPercent(usedPercent)) return;
	const normalized = Math.round(usedPercent * 10) / 10;
	if (snapshot.status === "ready" && snapshot.usedPercent === normalized) return;
	snapshot = { status: "ready", usedPercent: normalized, fetchedAt };
	if (persistQueued) return;
	persistQueued = true;
	queueMicrotask(() => {
		persistQueued = false;
		persist();
	});
}

function numericHeader(headers: Record<string, string>, name: string): number | undefined {
	const value = Number.parseFloat(headers[name] ?? headers[name.toLowerCase()] ?? "");
	return Number.isFinite(value) ? value : undefined;
}

export function registerCodexUsageCache(pi: ExtensionAPI): void {
	// Codex includes the real windows on each provider response. Prefer the
	// secondary (weekly) window and fall back to primary for older gateways.
	pi.on("after_provider_response", (event) => {
		const headers = event.headers as Record<string, string> | undefined;
		if (!headers) return;
		const used = numericHeader(headers, "x-codex-secondary-used-percent")
			?? numericHeader(headers, "x-codex-primary-used-percent");
		if (used !== undefined) observeCodexUsage(used);
	});
}
