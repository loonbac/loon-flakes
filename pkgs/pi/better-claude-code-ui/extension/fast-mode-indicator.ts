/**
 * Persistent in-chat indicator for pi-gpt-fast-mode-shared.
 *
 * The fast-mode package remains the single owner of its state and provider
 * hook.  This visual package only observes the small state file, so it never
 * needs to duplicate or interfere with the `/fast` command.
 */
import { readFileSync, watch } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

const WIDGET_KEY = "better-cc-ui.fast-mode";
const POLL_MS = 250;
const ANIMATION_MS = 120;
const RESET = "\x1b[0m";
const FAST_MODE_VISUAL_STATE = Symbol.for("better-cc-ui:fast-mode-visual-state");

interface FastModeVisualState {
	enabled: boolean;
	activatedAt: number | undefined;
}

interface AnimatedWidget {
	render(width: number): string[];
	invalidate(): void;
	dispose(): void;
}

interface WidgetTui {
	requestRender(): void;
}

export interface FastModeIndicatorUi {
	setWidget(key: string, content: ((tui: WidgetTui) => AnimatedWidget) | undefined): void;
}

function agentDirectory(): string {
	return process.env.PI_CODING_AGENT_DIR?.trim() || join(homedir(), ".pi", "agent");
}

function statePath(): string {
	return join(agentDirectory(), "state", "pi-gpt-fast-mode.json");
}

/** Match pi-gpt-fast-mode-shared's fallback when a session has no state file yet. */
function fastModeEnabled(): boolean {
	try {
		const state = JSON.parse(readFileSync(statePath(), "utf8")) as { enabled?: unknown };
		if (typeof state.enabled === "boolean") return state.enabled;
	} catch {
		// A missing file is normal before /fast has been used for the first time.
	}
	try {
		const settings = JSON.parse(readFileSync(join(agentDirectory(), "settings.json"), "utf8")) as Record<string, unknown>;
		const configured = settings["pi-gpt-fast-mode"];
		return typeof configured === "object" && configured !== null && (configured as { enabled?: unknown }).enabled === true;
	} catch {
		return false;
	}
}

function rgb(r: number, g: number, b: number): string {
	return `\x1b[38;2;${r};${g};${b}m`;
}

// This order is deliberately fixed. Animation advances through this ring; it
// never samples a random color or wallpaper accent.
const RGB_RING: ReadonlyArray<readonly [number, number, number]> = [
	[255, 78, 183],
	[187, 91, 255],
	[73, 160, 255],
	[66, 225, 211],
	[145, 238, 91],
	[255, 211, 70],
	[255, 128, 78],
];

function rainbow(text: string, phase: number): string {
	return [...text]
		.map((character, index) => {
			const [r, g, b] = RGB_RING[(index + phase) % RGB_RING.length]!;
			return `${rgb(r, g, b)}${character}`;
		})
		.join("") + RESET;
}

/** An animated, compact RGB rail shown above the editor only while Fast is on. */
function createFastModeBadge(tui: WidgetTui): AnimatedWidget {
	let phase = 0;
	const timer = setInterval(() => {
		phase = (phase + 1) % RGB_RING.length;
		tui.requestRender();
	}, ANIMATION_MS);
	(timer as unknown as { unref?: () => void }).unref?.();

	return {
		render(width: number): string[] {
			const rail = rainbow("▰▰▰▰▰▰▰▰▰", phase);
			if (width < 34) return [`  ${rail}  ${rainbow("FAST", phase + 2)}`];
			return [
				`  ${rail}  ${rainbow("⚡ FAST MODE", phase + 2)}${rgb(225, 240, 255)}  ·  GPT PRIORITY${RESET}`,
			];
		},
		invalidate() {},
		dispose(): void {
			clearInterval(timer);
		},
	};
}

function visualState(): FastModeVisualState | undefined {
	return (globalThis as unknown as Record<symbol, FastModeVisualState | undefined>)[FAST_MODE_VISUAL_STATE];
}

/**
 * Record the instant Fast becomes active for this running Pi process. Reloads
 * retain the same global state, so existing RGB-framed responses do not lose
 * their border just because extensions were reloaded.
 */
export function updateFastModeVisualState(enabled: boolean): void {
	const previous = visualState();
	if (previous === undefined) {
		(globalThis as unknown as Record<symbol, FastModeVisualState>)[FAST_MODE_VISUAL_STATE] = {
			enabled,
			activatedAt: enabled ? Date.now() : undefined,
		};
		return;
	}
	if (previous.enabled === enabled) return;
	previous.enabled = enabled;
	previous.activatedAt = enabled ? Date.now() : undefined;
}

/** Timestamp gate used by the transcript patch to leave earlier messages untouched. */
export function fastModeActivatedAt(): number | undefined {
	return visualState()?.activatedAt;
}

/** The tool patch snapshots this when a new execution begins. */
export function fastModeIsActive(): boolean {
	return visualState()?.enabled === true;
}

/** Shared clock for the prompt rail and every Fast-framed transcript block. */
export function fastModeAnimationPhase(): number {
	return Math.floor(Date.now() / ANIMATION_MS) % RGB_RING.length;
}

export class FastModeIndicator {
	private ui: FastModeIndicatorUi | undefined;
	private watcher: ReturnType<typeof watch> | undefined;
	private pollTimer: ReturnType<typeof setInterval> | undefined;
	private enabled: boolean | undefined;

	start(ui: FastModeIndicatorUi): void {
		this.stop();
		this.ui = ui;
		this.refresh();
		this.openWatcher();
		this.pollTimer = setInterval(() => this.refresh(), POLL_MS);
		(this.pollTimer as unknown as { unref?: () => void }).unref?.();
	}

	stop(): void {
		if (this.pollTimer !== undefined) clearInterval(this.pollTimer);
		this.pollTimer = undefined;
		this.watcher?.close();
		this.watcher = undefined;
		this.ui?.setWidget(WIDGET_KEY, undefined);
		this.ui = undefined;
		this.enabled = undefined;
	}

	private openWatcher(): void {
		const path = statePath();
		try {
			this.watcher = watch(dirname(path), (_eventType, changed) => {
				if (changed === null || changed.toString() === basename(path)) this.refresh();
			});
			this.watcher.unref?.();
		} catch {
			// The periodic read also covers a state directory created later.
		}
	}

	private refresh(): void {
		const enabled = fastModeEnabled();
		if (enabled === this.enabled) return;
		this.enabled = enabled;
		updateFastModeVisualState(enabled);
		this.ui?.setWidget(WIDGET_KEY, enabled ? createFastModeBadge : undefined);
	}
}
