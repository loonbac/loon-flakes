/**
 * Runtime patches on HOST classes — the extension-side landing of the
 * upstream PR draft (scratchpad/pi-upstream-pr.md). Remove once upstream
 * merges the equivalent fixes.
 *
 * Technique (learned from npm's pi-claude-code-ui / FammasMaz/pi-cc-tools):
 * `AssistantMessageComponent` and `InteractiveMode` are PUBLIC exports of
 * @earendil-works/pi-coding-agent, and pi's extension loader aliases that
 * specifier to the host's own running module (loader.js getAliases /
 * bundledModules) — so wrapping their prototype methods here patches the
 * live classes the host renders with. No host files are modified; the
 * patch ships with the extension.
 *
 * Patch 1 — AssistantMessageComponent.prototype.render:
 *   (a) A message whose entire rendered output is whitespace returns [].
 *   Why: updateContent predicts spacing from RAW message data — a non-empty
 *   thinking block earns a top Spacer(1) even when the thinking renders zero
 *   rows (our transformer collapses it, CC-style). Every thinking+toolCall
 *   message thus left one orphan blank row; with a thinking model and tool
 *   grouping (tools drawn by the group leader) those stacked into 8+
 *   consecutive blank rows after the group line. CC renders such
 *   intermediate messages as nothing at all.
 *   (b) Leading blank rows collapse to one. A thinking+text message renders
 *   [top Spacer, (thinking → 0 rows), trailing Spacer, body] — two blank
 *   rows before the body where CC has one. The first row is kept (it may
 *   carry the OSC133 copy-zone start mark), the redundant blanks after it
 *   are dropped. Legitimate messages never start with two blank rows: the
 *   host emits at most one top Spacer, and Markdown bodies are trimmed.
 *
 * Patch 2 — InteractiveMode.prototype.showStatus:
 *   Drops exactly the "Tool output: expanded|collapsed" notice. showStatus
 *   appends a Spacer+Text pair to chatContainer, so every Ctrl+O press left
 *   a permanent status row scrolling with the transcript. CC's ctrl+o is
 *   traceless — the expansion itself is the feedback. Every other
 *   showStatus message passes through untouched.
 *
 * Both wrappers call the original method and are Symbol-flag guarded
 * (idempotent across reloads and across multiple extension instances).
 */
import {
	AssistantMessageComponent,
	InteractiveMode,
	SessionSelectorComponent,
	ToolExecutionComponent,
	UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import {
	getKeybindings,
	isKeyRelease,
	isKittyProtocolActive,
	matchesKey,
	ProcessTerminal,
	stripTerminalSequences,
	visibleWidth,
	wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import { fastModeActivatedAt, fastModeAnimationPhase, fastModeIsActive } from "./fast-mode-indicator.js";
import {
	antigravityAUsageSnapshot,
	antigravityBUsageSnapshot,
	type AntigravityUsageSnapshot,
} from "./antigravity-usage.js";
import { openCodeGoUsageSnapshot, type OpenCodeGoUsageSnapshot } from "./opencode-go-usage.js";
import { commandCodeUsageSnapshot, type CommandCodeUsageSnapshot } from "./commandcode-usage.js";
import { codexUsageSnapshot, observeCodexUsage } from "./codex-usage-cache.js";
import { installFallbackPanelBehavior } from "./fallback-panel.js";

// CSI + OSC (BEL or ST terminated) + charset selects. OSC matters: the host
// render wraps a message's first/last row in OSC133 zone marks, which the
// all-blank check must see through.
// CSI parameters may use `:` (for example SGR 58:2::R:G:B, the underline
// colour used by the disabled weekly layer). They are zero-width too.
const ANSI_RE = /\x1b\[[0-9:;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][AB0]/g;

function isBlankRow(line: unknown): boolean {
	return typeof line === "string" && line.replace(ANSI_RE, "").trim() === "";
}

const BLANK_RENDER_FLAG = Symbol.for("better-cc-ui:assistant-blank-render");
const STATUS_FLAG = Symbol.for("better-cc-ui:tool-output-status");
const RESPONSE_BASE_RENDER = Symbol.for("better-cc-ui:response-base-render");
const USER_MESSAGE_BASE_RENDER = Symbol.for("better-cc-ui:user-message-base-render");
const TOOL_BASE_RENDER = Symbol.for("better-cc-ui:tool-base-render");
const ASSISTANT_UPDATE_BASE = Symbol.for("better-cc-ui:assistant-update-base");
const RESPONSE_FRAME_CACHE = Symbol.for("better-cc-ui:response-frame-cache");
const USER_MESSAGE_FRAME_CACHE = Symbol.for("better-cc-ui:user-message-frame-cache");
const TOOL_FRAME_CACHE = Symbol.for("better-cc-ui:tool-frame-cache");
const USER_MESSAGE_INVALIDATE_BASE = Symbol.for("better-cc-ui:user-message-invalidate-base");
const TOOL_INVALIDATE_BASE = Symbol.for("better-cc-ui:tool-invalidate-base");
const TOOL_MUTATION_BASES = Symbol.for("better-cc-ui:tool-mutation-bases");
const FAST_RESPONSE_FRAME = Symbol.for("better-cc-ui:fast-response-frame");
const TOOL_EXECUTION_START_BASE = Symbol.for("better-cc-ui:tool-execution-start-base");
const FAST_TOOL_FRAME = Symbol.for("better-cc-ui:fast-tool-frame");
const EXTENSION_UI_BASE = Symbol.for("better-cc-ui:extension-ui-base");
const EXTENSION_FOOTER_BASE = Symbol.for("better-cc-ui:extension-footer-base");
const GENTLE_MODEL_PANEL_RENDER_BASE = Symbol.for("better-cc-ui:gentle-model-panel-render-base");
// Kept as a symbol so this remains a Gentle patch, rather than an import from
// (or an edit to) Gentle's package.  That package owns this cache internally.
const GENTLE_SIDEBAR_CACHE = Symbol.for("gentle-pi.experimental-sidebar.cache");
const GENTLE_SIDEBAR_STATE = Symbol.for("gentle-pi.experimental-sidebar.state");
// This is the layout hook Gentle uses for its fullscreen rail.  We only read
// its resulting tree and decorate the rail component; Gentle stays untouched.
const LAYOUT_NODE = Symbol.for("@earendil-works/pi-tui/layout-node");
const GENTLE_SIDEBAR_RENDER_BASE = Symbol.for("better-cc-ui:gentle-sidebar-render-base");
const GENTLE_FOOTER_RENDER_BASE = Symbol.for("better-cc-ui:gentle-footer-render-base");
const GENTLE_TRANSCRIPT_SCROLLBAR_MODE = Symbol.for("better-cc-ui:gentle-transcript-scrollbar-mode");
const GENTLE_TRANSCRIPT_CONTENT_WIDTH_BASE = Symbol.for("better-cc-ui:gentle-transcript-content-width-base");
const GENTLE_TRANSCRIPT_GUTTER_ACTIVE = Symbol.for("better-cc-ui:gentle-transcript-gutter-active");
const GENTLE_RAIL_GUTTER_LAYOUT = Symbol.for("better-cc-ui:gentle-rail-gutter-layout");
const GENTLE_RAIL_LAYOUT_STABILIZER = Symbol.for("better-cc-ui:gentle-rail-layout-stabilizer");
const SESSION_SELECTOR_LAYOUT_BASE = Symbol.for("better-cc-ui:session-selector-layout-base");
const SESSION_LIST_INPUT_BASE = Symbol.for("better-cc-ui:session-list-input-base");
const SESSION_LIST_RENDER_BASE = Symbol.for("better-cc-ui:session-list-render-base");
const SESSION_HEADER_RENDER_BASE = Symbol.for("better-cc-ui:session-header-render-base");
const SESSION_DELETE_HOLD = Symbol.for("better-cc-ui:session-delete-hold");
const SESSION_DELETE_LATCH = Symbol.for("better-cc-ui:session-delete-latch");
// A session-local redraw bridge shared with wallpaper-sync.ts.  A symbol avoids
// a dependency on Gentle and leaves no API surface in that package.
const WALLPAPER_REDRAW = Symbol.for("better-cc-ui:wallpaper-redraw");
const TRANSCRIPT_THEME = Symbol.for("better-cc-ui:transcript-theme");
const OSC133_ZONE_START = "\x1b]133;A\x07";
const OSC133_ZONE_END = "\x1b]133;B\x07";
const OSC133_ZONE_FINAL = "\x1b]133;C\x07";
const OSC133_ZONE_RE = /\x1b\]133;[ABC]\x07/g;
const USER_MESSAGE_BACKGROUND_RE = /\x1b\[(?:4[0-7]|10[0-7]|48(?:[;:][0-9:;]*)?|49)m/g;

const DELETE_HOLD_MS = 900;
const DELETE_RETURN_MS = 420;
const DELETE_INITIAL_REPEAT_GRACE_MS = 700;
const DELETE_REPEAT_GRACE_MS = 350;
const DELETE_RED = "\x1b[38;2;244;72;92m";
const DELETE_RED_BACKGROUND = "\x1b[48;2;132;31;48m";

interface ResumeSessionInfo {
	path: string;
	name?: string;
	firstMessage?: string;
}

interface ResumeSessionNode {
	session: ResumeSessionInfo;
	depth: number;
	isLast: boolean;
	ancestorContinues: boolean[];
}

interface DeleteHoldState {
	path: string;
	lastEventAt: number;
	lastTickAt: number;
	events: number;
	progress: number;
	held: boolean;
	timer: ReturnType<typeof setInterval>;
}

interface DeleteLatchState {
	timer: ReturnType<typeof setTimeout>;
}

interface PatchedSessionList {
	filteredSessions: ResumeSessionNode[];
	selectedIndex: number;
	maxVisible: number;
	onDeleteSession?: (sessionPath: string) => Promise<void>;
	onError?: (message: string) => void;
	getSelectedSessionPath: () => string | undefined;
	isCurrentSessionPath?: (path: string) => boolean;
	buildTreePrefix?: (node: ResumeSessionNode) => string;
	handleInput: (data: string) => void;
	render: (width: number) => string[];
	[SESSION_LIST_INPUT_BASE]?: (data: string) => void;
	[SESSION_LIST_RENDER_BASE]?: (width: number) => string[];
	[SESSION_DELETE_HOLD]?: DeleteHoldState;
	[SESSION_DELETE_LATCH]?: DeleteLatchState;
}

interface PatchedSessionHeader {
	render: (width: number) => string[];
	[SESSION_HEADER_RENDER_BASE]?: (width: number) => string[];
}

interface PatchedSessionSelector {
	sessionList?: PatchedSessionList;
	header?: PatchedSessionHeader;
	requestRender?: () => void;
}

/** Keep every SGR/OSC token, but replace a range measured in visible cells. */
function replaceVisibleCells(
	line: string,
	startCell: number,
	endCell: number,
	replacement: string,
): string {
	const tokenRe = new RegExp(`(${ANSI_RE.source})`, "g");
	const tokens = line.split(tokenRe);
	let column = 0;
	let inserted = false;
	let result = "";
	for (const token of tokens) {
		if (!token) continue;
		if (token.startsWith("\x1b")) {
			result += token;
			continue;
		}
		for (const char of token) {
			if (!inserted && column >= startCell) {
				result += replacement;
				inserted = true;
			}
			const nextColumn = column + visibleWidth(char);
			if (nextColumn <= startCell || column >= endCell) result += char;
			column = nextColumn;
		}
	}
	if (!inserted) result += replacement;
	return result;
}

function backgroundAtVisibleCell(line: string, targetCell: number): string {
	const tokenRe = new RegExp(`(${ANSI_RE.source})`, "g");
	let column = 0;
	let background = "\x1b[49m";
	for (const token of line.split(tokenRe)) {
		if (!token) continue;
		if (token.startsWith("\x1b")) {
			if (column <= targetCell) {
				const sgr = /^\x1b\[([0-9:;]*)m$/u.exec(token)?.[1] ?? "";
				if (/(?:^|[;:])(?:0|49)(?:[;:]|$)/u.test(sgr)) background = "\x1b[49m";
				if (/(?:^|[;:])(?:4[0-8]|10[0-7])(?:[;:]|$)/u.test(sgr)) background = token;
			}
			continue;
		}
		for (const char of token) {
			if (column >= targetCell) return background;
			column += visibleWidth(char);
		}
	}
	return background;
}

function paintVisibleBackground(line: string, startCell: number, endCell: number): string {
	if (endCell <= startCell) return line;
	const restoreBackground = backgroundAtVisibleCell(line, startCell);
	const opened = replaceVisibleCells(line, startCell, startCell, DELETE_RED_BACKGROUND);
	return replaceVisibleCells(opened, endCell, endCell, restoreBackground);
}

function clearDeleteHold(list: PatchedSessionList, requestRender: () => void): void {
	const state = list[SESSION_DELETE_HOLD];
	if (!state) return;
	clearInterval(state.timer);
	delete list[SESSION_DELETE_HOLD];
	requestRender();
}

function releaseDeleteHold(list: PatchedSessionList, requestRender: () => void): void {
	const state = list[SESSION_DELETE_HOLD];
	if (!state || !state.held) return;
	state.held = false;
	state.lastTickAt = Date.now();
	requestRender();
}

function clearDeleteLatch(list: PatchedSessionList): void {
	const latch = list[SESSION_DELETE_LATCH];
	if (!latch) return;
	clearTimeout(latch.timer);
	delete list[SESSION_DELETE_LATCH];
}

function keepDeleteLatched(list: PatchedSessionList): void {
	clearDeleteLatch(list);
	const latch = {
		timer: undefined as unknown as ReturnType<typeof setTimeout>,
	};
	// Legacy terminals have no release event. Repeated Delete events keep this
	// timer armed; after the physical key is released, a fresh hold is allowed.
	latch.timer = setTimeout(() => {
		if (list[SESSION_DELETE_LATCH] === latch) delete list[SESSION_DELETE_LATCH];
	}, 500);
	list[SESSION_DELETE_LATCH] = latch;
}

function decorateResumeSelector(selector: PatchedSessionSelector): void {
	const list = selector.sessionList;
	const header = selector.header;
	if (!list || !header) return;
	const requestRender = () => selector.requestRender?.();

	if (!header[SESSION_HEADER_RENDER_BASE]) {
		const originalHeaderRender = header.render.bind(header);
		header[SESSION_HEADER_RENDER_BASE] = originalHeaderRender;
		header.render = (width: number): string[] => {
			const lines = originalHeaderRender(width);
			const hint = lines[2];
			if (typeof hint !== "string") return lines;
			const plain = stripTerminalSequences(hint);
			const match = /ctrl\+d delete/u.exec(plain);
			if (!match || match.index === undefined) return lines;
			const start = visibleWidth(plain.slice(0, match.index));
			const end = start + visibleWidth(match[0]);
			lines[2] = replaceVisibleCells(
				hint,
				start,
				end,
				`${DELETE_RED}Supr\x1b[39m mantener`,
			);
			return lines;
		};
	}

	if (!list[SESSION_LIST_RENDER_BASE]) {
		const originalListRender = list.render.bind(list);
		list[SESSION_LIST_RENDER_BASE] = originalListRender;
		list.render = (width: number): string[] => {
			const lines = originalListRender(width);
			const state = list[SESSION_DELETE_HOLD];
			if (!state || list.getSelectedSessionPath() !== state.path) return lines;
			const startIndex = Math.max(
				0,
				Math.min(
					list.selectedIndex - Math.floor(list.maxVisible / 2),
					list.filteredSessions.length - list.maxVisible,
				),
			);
			const row = 2 + list.selectedIndex - startIndex;
			const line = lines[row];
			if (typeof line !== "string") return lines;
			const rowWidth = visibleWidth(line);
			const painted = Math.max(1, Math.ceil(rowWidth * state.progress));
			lines[row] = paintVisibleBackground(line, 0, painted);
			return lines;
		};
	}

	if (!list[SESSION_LIST_INPUT_BASE]) {
		const originalListInput = list.handleInput.bind(list);
		list[SESSION_LIST_INPUT_BASE] = originalListInput;
		list.handleInput = (data: string): void => {
			const keybindings = getKeybindings();
			// Retire Pi's Ctrl+D / Ctrl+Backspace confirmation flow. Deletion in
			// /resume is intentionally available only through the hold gesture.
			if (
				keybindings.matches(data, "app.session.delete") ||
				keybindings.matches(data, "app.session.deleteNoninvasive")
			) {
				clearDeleteHold(list, requestRender);
				clearDeleteLatch(list);
				return;
			}
			if (!matchesKey(data, "delete")) {
				releaseDeleteHold(list, requestRender);
				clearDeleteLatch(list);
				originalListInput(data);
				return;
			}
			if (isKeyRelease(data)) {
				releaseDeleteHold(list, requestRender);
				clearDeleteLatch(list);
				return;
			}
			if (list[SESSION_DELETE_LATCH]) {
				keepDeleteLatched(list);
				return;
			}

			const path = list.getSelectedSessionPath();
			if (!path) return;
			if (list.isCurrentSessionPath?.(path)) {
				clearDeleteHold(list, requestRender);
				list.onError?.("No se puede borrar la sesión activa");
				return;
			}
			const now = Date.now();
			const existing = list[SESSION_DELETE_HOLD];
			if (existing?.path === path) {
				existing.lastEventAt = now;
				existing.events += 1;
				if (!existing.held) existing.lastTickAt = now;
				existing.held = true;
				requestRender();
				return;
			}
			clearDeleteHold(list, requestRender);
			const state = {
				path,
				lastEventAt: now,
				lastTickAt: now,
				events: 1,
				progress: 0,
				held: true,
				timer: undefined as unknown as ReturnType<typeof setInterval>,
			};
			state.timer = setInterval(() => {
				if (list[SESSION_DELETE_HOLD] !== state) {
					clearInterval(state.timer);
					return;
				}
				const tick = Date.now();
				const delta = Math.max(0, tick - state.lastTickAt);
				state.lastTickAt = tick;
				const grace = state.events > 1 ? DELETE_REPEAT_GRACE_MS : DELETE_INITIAL_REPEAT_GRACE_MS;
				if (
					state.held && (
						(state.events === 1 && tick - state.lastEventAt > grace) ||
						(state.events > 1 && !isKittyProtocolActive() && tick - state.lastEventAt > grace)
					)
				) {
					state.held = false;
				}
				state.progress = state.held
					? Math.min(1, state.progress + delta / DELETE_HOLD_MS)
					: Math.max(0, state.progress - delta / DELETE_RETURN_MS);
				if (state.progress <= 0 && !state.held) {
					clearDeleteHold(list, requestRender);
					return;
				}
				// At least one repeat is mandatory. This keeps a lone Delete press
				// harmless even on terminals that cannot report key releases.
				if (state.progress >= 1 && state.events > 1 && state.held) {
					clearInterval(state.timer);
					delete list[SESSION_DELETE_HOLD];
					keepDeleteLatched(list);
					requestRender();
					void list.onDeleteSession?.(state.path);
					return;
				}
				requestRender();
			}, 32);
			list[SESSION_DELETE_HOLD] = state;
			requestRender();
		};
	}
}

interface TranscriptTheme {
	fg?: (role: string, text: string) => string;
}

type TranscriptFrameCache = {
	width: number;
	phase: number;
	body: string[];
	lines: string[];
	state?: unknown;
};

// The host's Theme is a stable proxy whose color roles are updated in-place by
// wallpaper-sync. Keeping the proxy (not a copied ANSI value) makes historical
// user cards recolor immediately with the current wallpaper palette. Store it
// behind Symbol.for as well: during /reload Pi may create the extension context
// before evaluating this fresh module instance.
const sharedHostState = globalThis as unknown as Record<symbol, unknown>;
let transcriptTheme = sharedHostState[TRANSCRIPT_THEME] as TranscriptTheme | undefined;
// Truecolor, rather than ANSI 15: Ghostty's palette can map ANSI 15 to a
// muted gray when a terminal theme is active.
const BRIGHT_TEXT = "\x1b[38;2;245;245;245m";
const WEEKLY_SKY = "\x1b[38;2;102;202;255m";
const WEEKLY_SKY_BACKGROUND = "\x1b[48;2;30;90;116m";
// The weekly outline is sky blue while quota remains and red only once that
// pool is exhausted/disabled. The light five-hour glyph is painted over it.
const WEEKLY_OUTER_RED = "\x1b[38;2;244;72;92m";
const WEEKLY_OUTER_RED_BACKGROUND = "\x1b[48;2;132;31;48m";
const MONTHLY_YELLOW_UNDERLINE = "\x1b[58:2::245:194:66m";
// Ghostty's xterm-ghostty terminfo supports styled underlines.  Double
// underline makes the monthly layer readable through a transparent terminal
// without adding a separate row or covering the 5 h / weekly layers.
const UNDERLINE_ON = "\x1b[4:2m";
const RESET_UNDERLINE = "\x1b[24m";
const RESET_UNDERLINE_COLOR = "\x1b[59m";
const METER_EMPTY = "\x1b[38;2;135;145;158m";
const DISABLED_RED = "\x1b[38;2;255;98;120m";
const RESET_BACKGROUND = "\x1b[49m";
const RESET_FOREGROUND_RE = /\x1b\[39m/g;

// Every 18x36 sprite occupies exactly one terminal cell. The four variants per
// outer state keep the larger weekly parallelogram geometrically identical as
// its colour drains cell by cell, independently from the white five-hour fill
// and the optional monthly yellow baseline.
type QuotaOuterState = "sky" | "dim" | "red";
const QUOTA_SPRITES = [
	[201, 1, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkBAMAAAB2w3fUAAAAKlBMVEUAAABmyv9myv9myv9myv9myv9myv9myv9myv9myv9myv9myv9myv9myv93UspNAAAADXRSTlMAABZW7BDAdAomPAOY1HevRQAAAGFJREFUGNNjYBh4wHQXAhgYmF1DQcCEgYGtACyVzsDQOwHE4LjJwLB2A4jFdZuB4QxYkucAA/ctMGvvAgbOG2DW3AYG9gQwq4yBgcUAxGB0ZmDghdhwiYGBFWxDaACd/QgAZ08c3eAT/HQAAAAASUVORK5CYII="],
	[202, 2, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkCAMAAACzM5rVAAAAM1BMVEUAAABmyv9myv9myv9myv9myv9myv9myv9myv9myv/19fVmyv9myv/19fVmyv9myv/19fUs4N2zAAAAD3RSTlMAABZW7BDAdAomAzwDTphg7yr9AAAAX0lEQVQoz+WQSQ7AIAzEKPua8P/XdihCgQdUPdQ3W4NAKPVbNB+MZKwTjB3Jh+3II5FT7gsIUuHaVmkQJCIZZSKUykVGEKTEUUYQpOC3+6ZYI+Wacj5dj+QOvv7cN7gBzIYG0+s7SSEAAAAASUVORK5CYII="],
	[203, 3, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkBAMAAAB2w3fUAAAAMFBMVEUAAABmyv9myv9myv9myv9myv9myv9myv9myv9myv9myv9myv9myv/1wkJmyv/1wkKBWIQ+AAAADnRSTlMAABZW7BDAdAomPAOYEMnXPVkAAABuSURBVBjTY2AYeMD0DgIYGJhdQ0HAhIGBrQAslc7A0DcBxOB4ycCwbgOIxfWageEMWJLnAAP3KzBr3wIGzhdg1rwGBvYEMKuMgYHFAMRgdGZg4IPY8IiBgRVsQ2gAOQ7l/w8Bfxl470LABWK1AgAhQCz8fNBywAAAAABJRU5ErkJggg=="],
	[204, 4, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkCAMAAACzM5rVAAAAOVBMVEUAAABmyv9myv9myv9myv9myv9myv9myv9myv9myv/19fVmyv9myv/19fVmyv/1wkJmyv/19fX1wkLM/MExAAAAEHRSTlMAABZW7BDAdAomAzwDTpgQDNmeYgAAAGdJREFUKM/lkEsOgCAMBSt/5Fe9/2F9aEzBtXHj7GZSUlKi36J4oidtrKBNT84PT04JHNftBoKUOJe7FAhSrTK01oqSOckQBClykCEIknfDvkuMlrJcMn9d9WQnvjjg/qARtQev7jsA/mEJQVlkoGMAAAAASUVORK5CYII="],
	[205, 5, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkBAMAAAB2w3fUAAAAKlBMVEUAAACHkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6THgDFAAAADXRSTlMAABZW7BDAdAomPAOY1HevRQAAAGFJREFUGNNjYBh4wHQXAhgYmF1DQcCEgYGtACyVzsDQOwHE4LjJwLB2A4jFdZuB4QxYkucAA/ctMGvvAgbOG2DW3AYG9gQwq4yBgcUAxGB0ZmDghdhwiYGBFWxDaACd/QgAZ08c3eAT/HQAAAAASUVORK5CYII="],
	[206, 6, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkCAMAAACzM5rVAAAAM1BMVEUAAACHkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ719fWHkZ6HkZ719fWHkZ6HkZ719fUuHH/iAAAAD3RSTlMAABZW7BDAdAomAzwDTphg7yr9AAAAX0lEQVQoz+WQSQ7AIAzEKPua8P/XdihCgQdUPdQ3W4NAKPVbNB+MZKwTjB3Jh+3II5FT7gsIUuHaVmkQJCIZZSKUykVGEKTEUUYQpOC3+6ZYI+Wacj5dj+QOvv7cN7gBzIYG0+s7SSEAAAAASUVORK5CYII="],
	[207, 7, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkBAMAAAB2w3fUAAAAMFBMVEUAAACHkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ71wkKHkZ71wkK2tub6AAAADnRSTlMAABZW7BDAdAomPAOYEMnXPVkAAABuSURBVBjTY2AYeMD0DgIYGJhdQ0HAhIGBrQAslc7A0DcBxOB4ycCwbgOIxfWageEMWJLnAAP3KzBr3wIGzhdg1rwGBvYEMKuMgYHFAMRgdGZg4IPY8IiBgRVsQ2gAOQ7l/w8Bfxl470LABWK1AgAhQCz8fNBywAAAAABJRU5ErkJggg=="],
	[208, 8, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkCAMAAACzM5rVAAAAOVBMVEUAAACHkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ6HkZ719fWHkZ6HkZ719fWHkZ71wkKHkZ719fX1wkJwt+wkAAAAEHRSTlMAABZW7BDAdAomAzwDTpgQDNmeYgAAAGdJREFUKM/lkEsOgCAMBSt/5Fe9/2F9aEzBtXHj7GZSUlKi36J4oidtrKBNT84PT04JHNftBoKUOJe7FAhSrTK01oqSOckQBClykCEIknfDvkuMlrJcMn9d9WQnvjjg/qARtQev7jsA/mEJQVlkoGMAAAAASUVORK5CYII="],
	[209, 9, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkBAMAAAB2w3fUAAAAKlBMVEUAAAD0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFyFkDCgAAAADXRSTlMAABZW7BDAdAomPAOY1HevRQAAAGFJREFUGNNjYBh4wHQXAhgYmF1DQcCEgYGtACyVzsDQOwHE4LjJwLB2A4jFdZuB4QxYkucAA/ctMGvvAgbOG2DW3AYG9gQwq4yBgcUAxGB0ZmDghdhwiYGBFWxDaACd/QgAZ08c3eAT/HQAAAAASUVORK5CYII="],
	[210, 10, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkCAMAAACzM5rVAAAAM1BMVEUAAAD0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz19fX0SFz0SFz19fX0SFz0SFz19fUD6/fwAAAAD3RSTlMAABZW7BDAdAomAzwDTphg7yr9AAAAX0lEQVQoz+WQSQ7AIAzEKPua8P/XdihCgQdUPdQ3W4NAKPVbNB+MZKwTjB3Jh+3II5FT7gsIUuHaVmkQJCIZZSKUykVGEKTEUUYQpOC3+6ZYI+Wacj5dj+QOvv7cN7gBzIYG0+s7SSEAAAAASUVORK5CYII="],
	[211, 11, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkBAMAAAB2w3fUAAAAMFBMVEUAAAD0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz1wkL0SFz1wkIEaoYQAAAADnRSTlMAABZW7BDAdAomPAOYEMnXPVkAAABuSURBVBjTY2AYeMD0DgIYGJhdQ0HAhIGBrQAslc7A0DcBxOB4ycCwbgOIxfWageEMWJLnAAP3KzBr3wIGzhdg1rwGBvYEMKuMgYHFAMRgdGZg4IPY8IiBgRVsQ2gAOQ7l/w8Bfxl470LABWK1AgAhQCz8fNBywAAAAABJRU5ErkJggg=="],
	[212, 12, "iVBORw0KGgoAAAANSUhEUgAAABIAAAAkCAMAAACzM5rVAAAAOVBMVEUAAAD0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz0SFz19fX0SFz0SFz19fX0SFz1wkL0SFz19fX1wkJEaQhpAAAAEHRSTlMAABZW7BDAdAomAzwDTpgQDNmeYgAAAGdJREFUKM/lkEsOgCAMBSt/5Fe9/2F9aEzBtXHj7GZSUlKi36J4oidtrKBNT84PT04JHNftBoKUOJe7FAhSrTK01oqSOckQBClykCEIknfDvkuMlrJcMn9d9WQnvjjg/qARtQev7jsA/mEJQVlkoGMAAAAASUVORK5CYII="],
] as const;
// Revisioned so the first reload after introducing redraw persistence always
// transmits fresh image data instead of trusting the now-deleted v3 sprites.
const QUOTA_SPRITES_UPLOADED = Symbol.for("better-cc-ui:quota-sprites-uploaded-v8");
const QUOTA_TERMINAL_WRITE_BASE = Symbol.for("better-cc-ui:quota-terminal-write-base");
const KITTY_IMAGE_PLACEHOLDER = "\u{10eeee}\u0305\u0305";
const KITTY_DELETE_ALL_IMAGES = "\x1b_Ga=d,d=A,q=2\x1b\\";
let quotaSpritesReady = false;

function kittyPlaceholder(imageId: number, placementId: number): string {
	// U+10EEEE reads its image ID from foreground colour. Palette form mirrors
	// the protocol's canonical one-cell example. Underline colour carries the
	// explicit virtual placement ID; no terminal underline is enabled.
	return `${RESET_UNDERLINE}\x1b[38;5;${imageId}m\x1b[58;5;${placementId}m${KITTY_IMAGE_PLACEHOLDER}${RESET_UNDERLINE_COLOR}\x1b[39m`;
}

/** Upload invisible virtual sprites. Their placeholders later move, clip and
 * redraw as ordinary one-cell text within Pi's compositor. */
function quotaSpriteUploadCommands(): string {
	const upload = (imageId: number, placementId: number, png: string) =>
		`\x1b_Ga=t,f=100,q=2,i=${imageId};${png}\x1b\\` +
		`\x1b_Ga=p,q=2,U=1,i=${imageId},p=${placementId},c=1,r=1\x1b\\`;
	return QUOTA_SPRITES.map(([imageId, placementId, png]) => upload(imageId, placementId, png)).join("");
}

/** pi-tui intentionally deletes every Kitty image before a fullscreen redraw.
 * These inline sprites are not normal transcript attachments, so re-upload
 * them in that same synchronized frame, after deletion and before row paint. */
function installQuotaSpritePersistence(): void {
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const terminalProto = ProcessTerminal.prototype as any;
	if (typeof terminalProto.write !== "function") return;
	const originalWrite = terminalProto[QUOTA_TERMINAL_WRITE_BASE] ?? terminalProto.write;
	terminalProto[QUOTA_TERMINAL_WRITE_BASE] = originalWrite;
	terminalProto.write = function ccUiKeepQuotaSprites(data: string): unknown {
		if (
			quotaSpritesReady &&
			typeof data === "string" &&
			data.includes(KITTY_DELETE_ALL_IMAGES) &&
			data.includes("\x1b[2J")
		) {
			data = data.replace(
				KITTY_DELETE_ALL_IMAGES,
				KITTY_DELETE_ALL_IMAGES + quotaSpriteUploadCommands(),
			);
		}
		return originalWrite.call(this, data);
	};
}

function prepareQuotaMeterSprites(): void {
	const state = globalThis as Record<symbol, unknown>;
	if (state[QUOTA_SPRITES_UPLOADED] === true) {
		quotaSpritesReady = true;
		return;
	}
	if (!process.stdout.isTTY || process.env.TERM_PROGRAM?.toLowerCase() !== "ghostty" || process.env.TMUX) return;
	try {
		process.stdout.write(quotaSpriteUploadCommands());
		state[QUOTA_SPRITES_UPLOADED] = true;
		quotaSpritesReady = true;
	} catch {
		// A normal one-cell Unicode meter remains available as fallback.
	}
}

function quotaLayerSprite(outer: QuotaOuterState, inner: boolean, monthly: boolean): string | undefined {
	if (!quotaSpritesReady) return undefined;
	const stateOffset = outer === "sky" ? 0 : outer === "dim" ? 4 : 8;
	const variantOffset = (monthly ? 2 : 0) + (inner ? 1 : 0);
	const [imageId, placementId] = QUOTA_SPRITES[stateOffset + variantOffset];
	return kittyPlaceholder(imageId, placementId);
}

/** Terminal controls are zero-width, including OSC133 copy-zone marks. */
const TERMINAL_CONTROL_RE = /\x1b\[[0-9:;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\\\)|\x1b[()][AB0]/g;

function displayWidth(line: string): number {
	// pi-tui knows grapheme widths (including Kitty's U+10EEEE image
	// placeholder); its row/column diacritics must remain zero-width.
	return visibleWidth(line);
}

function isOnlyWhitespace(line: string): boolean {
	return line.replace(TERMINAL_CONTROL_RE, "").trim() === "";
}

const GENTLE_MODEL_PANEL_TITLES = [
	"Assign Models and Effort to Agents",
	"Select model for ",
	"Select effort for ",
] as const;

/** Translate an offset in the control-free text back to its raw ANSI string.
 * Gentle emits only foreground SGR spans here, so an underline can safely
 * cross those spans without changing their colours. */
function rawOffsetForPlainOffset(line: string, target: number): number {
	let rawOffset = 0;
	let plainOffset = 0;
	const controls = new RegExp(TERMINAL_CONTROL_RE.source, "gy");
	while (rawOffset < line.length && plainOffset < target) {
		controls.lastIndex = rawOffset;
		const control = controls.exec(line);
		if (control) {
			rawOffset = controls.lastIndex;
			continue;
		}
		const codePoint = line.codePointAt(rawOffset);
		const length = codePoint !== undefined && codePoint > 0xffff ? 2 : 1;
		rawOffset += length;
		plainOffset += length;
	}
	return rawOffset;
}

/** Keep Gentle's cursor and underline exactly the selected label. Padding and
 * card borders remain untouched, which makes the focus clear without drawing
 * a distracting full-width rule across the modal. */
function underlineGentleModelPanelSelection(lines: string[]): string[] {
	const isModelPanel = lines.some((line) => {
		const plain = stripTerminalSequences(line);
		return GENTLE_MODEL_PANEL_TITLES.some((title) => plain.includes(title));
	});
	if (!isModelPanel) return lines;

	return lines.map((line) => {
		const plain = stripTerminalSequences(line);
		const cursor = plain.indexOf("▸ ");
		if (cursor < 0) return line;

		const labelStart = cursor + "▸ ".length;
		const rightBorder = plain.lastIndexOf(" │");
		let labelEnd = rightBorder >= labelStart ? rightBorder : plain.length;
		while (labelEnd > labelStart && plain[labelEnd - 1] === " ") labelEnd--;
		if (labelEnd <= labelStart) return line;

		const rawStart = rawOffsetForPlainOffset(line, labelStart);
		const rawEnd = rawOffsetForPlainOffset(line, labelEnd);
		return `${line.slice(0, rawStart)}\x1b[4m${line.slice(rawStart, rawEnd)}\x1b[24m${line.slice(rawEnd)}`;
	});
}

function decorateGentleModelPanel(component: unknown, tui?: { requestRender?: () => void }): unknown {
	if (!component || typeof component !== "object") return component;
	installFallbackPanelBehavior(component, tui ?? {});
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const panel = component as any;
	if (typeof panel.render !== "function") return component;
	const originalRender = panel[GENTLE_MODEL_PANEL_RENDER_BASE] ?? panel.render;
	panel[GENTLE_MODEL_PANEL_RENDER_BASE] = originalRender;
	panel.render = function ccUiUnderlineGentleModelSelection(width: number): string[] {
		const lines = originalRender.call(this, width);
		return Array.isArray(lines) ? underlineGentleModelPanelSelection(lines) : lines;
	};
	return component;
}

/** Give only Gentle's model-routing panel enough room for two complete model
 * identifiers side by side. Keep every other custom overlay at its own size. */
function patchGentleOverlayOptions(factory: unknown, args: unknown[]): unknown[] {
	if (typeof factory !== "function") return args;
	const factorySource = String(factory);
	const isModelsPanel = factorySource.includes("SddModelPanel");
	const isAgentsPanel = factorySource.includes("AgentsView");
	if (!isModelsPanel && !isAgentsPanel) return args;
	const options = args[0];
	if (!options || typeof options !== "object") return args;
	const customOptions = options as Record<string, unknown>;
	const overlayOptions = customOptions.overlayOptions;
	if (!overlayOptions || typeof overlayOptions !== "object") return args;
	return [
		{
			...customOptions,
			overlayOptions: {
				...(overlayOptions as Record<string, unknown>),
				...(isModelsPanel
					? { width: "98%", minWidth: 120 }
					: { width: "80%", maxHeight: "78%", margin: 1, anchor: "center" }),
			},
		},
		...args.slice(1),
	];
}

/**
 * AgentsView derives its body height from `tui.terminal.rows`, even when Pi
 * places it inside a smaller overlay. Supplying a shallow proxy keeps every
 * operation connected to the real TUI while making that one dimension match
 * the overlay. This lets Gentle render its own footer and bottom border
 * instead of Pi clipping them after the fact.
 */
function tuiForGentleAgentsOverlay(tui: unknown): unknown {
	if (!tui || typeof tui !== "object") return tui;
	const tuiRecord = tui as Record<PropertyKey, unknown>;
	const terminal = tuiRecord.terminal;
	if (!terminal || typeof terminal !== "object") return tui;
	const terminalRecord = terminal as Record<PropertyKey, unknown>;
	const rows = terminalRecord.rows;
	if (typeof rows !== "number" || !Number.isFinite(rows) || rows <= 0) return tui;

	const overlayRows = Math.max(12, Math.min(rows, Math.floor(rows * 0.78)));
	const terminalProxy = new Proxy(terminalRecord, {
		get(target, property) {
			if (property === "rows") return overlayRows;
			const value = Reflect.get(target, property, target);
			return typeof value === "function" ? value.bind(target) : value;
		},
		set(target, property, value) {
			return Reflect.set(target, property, value, target);
		},
	});

	return new Proxy(tuiRecord, {
		get(target, property) {
			if (property === "terminal") return terminalProxy;
			const value = Reflect.get(target, property, target);
			return typeof value === "function" ? value.bind(target) : value;
		},
		set(target, property, value) {
			return Reflect.set(target, property, value, target);
		},
	});
}

/** Remove Gentle's ornamental rail banner and its following section spacer. */
function withoutGentleSidebarBanner(lines: string[]): string[] {
	const filtered: string[] = [];
	let skipSpacer = false;
	for (const line of lines) {
		if (line.replace(TERMINAL_CONTROL_RE, "").includes("Gentle-Pi")) {
			skipSpacer = true;
			continue;
		}
		if (skipSpacer && isOnlyWhitespace(line)) {
			skipSpacer = false;
			continue;
		}
		skipSpacer = false;
		filtered.push(line);
	}
	return filtered;
}

/**
 * Gentle's compact footer is independent from the rail banner.  Keep its
 * useful live segments (project, branch, model, context and usage), while
 * removing only the leading brand segment and the separator it owns.
 *
 * The match includes terminal controls because Gentle paints every segment
 * separately; stripping plain text alone would leave a coloured orphan
 * separator or reset sequence at the beginning of Pi's status line.
 */
function withoutGentleStatusBrand(lines: string[]): string[] {
	const control = String.raw`(?:\x1b\[[0-9:;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\))`;
	const prefix = new RegExp(
		String.raw`^(?:${control})*✿\s*gentle-pi(?:${control})*\s+(?:${control})*⟡(?:${control})*\s*`,
	);
	return lines.map((line) => line.replace(prefix, ""));
}

/** The right rail already owns project and branch; omit their footer segment. */
function withoutGentleStatusLocation(lines: string[]): string[] {
	return lines.map((line) => {
		const separator = line.indexOf("⟡");
		if (separator < 0) return line;
		// The separator has its own paint/reset sequence. Drop it too, but leave
		// the next segment's colour untouched.
		return line.slice(separator + "⟡".length).replace(new RegExp(String.raw`^(?:\x1b\[[0-9:;?]*[ -/]*[@-~])*\s*`), "");
	});
}

/**
 * With brand/project/branch gone, a normal shell bar leaves most of a wide
 * terminal blank. Spread its remaining live groups across the same one-line
 * status bar: model → context → cost → usage.  The styled `⟡` separators stay
 * intact; only their surrounding whitespace grows.
 */
function stretchGentleStatusLine(lines: string[], width: number): string[] {
	const separator = /(\s*)(\x1b\[[0-9:;?]*[ -/]*[@-~]⟡\x1b\[[0-9:;?]*[ -/]*[@-~])(\s*)/g;
	return lines.map((line) => {
		const separators = [...line.matchAll(separator)];
		const spare = width - displayWidth(line);
		if (separators.length === 0 || spare <= 0) return line;

		const slots = separators.length * 2;
		const perSlot = Math.floor(spare / slots);
		let remainder = spare % slots;
		const extraSpace = () => " ".repeat(perSlot + (remainder-- > 0 ? 1 : 0));
		return line.replace(separator, (_whole, before: string, painted: string, after: string) =>
			`${before}${extraSpace()}${painted}${after}${extraSpace()}`,
		);
	});
}

/** Text inside a Gentle card row, excluding its styled left/right rails. */
function gentleCardBody(line: string): string | undefined {
	const plain = line.replace(TERMINAL_CONTROL_RE, "");
	const left = plain.indexOf("│");
	const right = plain.lastIndexOf("│");
	if (left < 0 || right <= left) return undefined;
	return plain.slice(left + 1, right).trim();
}

/** Model and context belong to Gentle's one-line footer, not the rail card. */
function withoutGentleSidebarRuntimeDetails(lines: string[]): string[] {
	const filtered: string[] = [];
	let skipping = false;
	for (const line of lines) {
		const body = gentleCardBody(line);
		if (body === "Model" || body === "Context") {
			skipping = true;
			continue;
		}
		if (skipping) {
			// A blank card row closes one logical group. Consume it too, so there
			// is one intentional separator between Project and Usage.
			if (body === "") skipping = false;
			continue;
		}
		filtered.push(line);
	}
	return filtered;
}

/** The fallback editor is now the canonical view of the configured chain.
 * Remove Gentle's duplicate summary while retaining the independent Engram
 * and MCP status rows that follow it. */
function withoutGentleSidebarFallbackSummary(lines: string[]): string[] {
	const filtered: string[] = [];
	let skippingSummary = false;
	for (const line of lines) {
		const body = gentleCardBody(line);
		if (body === "Integrations") {
			skippingSummary = true;
			continue;
		}
		if (skippingSummary) {
			const isRuntimeStatus = /^(?:🧠||🔌|)\s/.test(body ?? "");
			if (!isRuntimeStatus && body !== "") continue;
			skippingSummary = false;
		}
		filtered.push(line);
	}
	return filtered;
}

function clipPlainText(text: string, width: number): string {
	if (displayWidth(text) <= width) return text;
	if (width <= 1) return "…".slice(0, width);
	return `${[...text].slice(0, width - 1).join("")}…`;
}

/**
 * Reuse Gentle's original card row (and, therefore, its wallpaper-driven
 * borders) while replacing only the content between the two rails.
 */
function gentleCardRow(template: string, body: string): string {
	const left = template.indexOf("│");
	const right = template.lastIndexOf("│");
	if (left < 0 || right <= left) return template;
	const usableWidth = Math.max(0, displayWidth(template.slice(left + 1, right)) - 2);
	const shown = clipPlainText(body, usableWidth);
	const padding = " ".repeat(Math.max(0, usableWidth - displayWidth(shown)));
	return `${template.slice(0, left + 1)} ${BRIGHT_TEXT}${shown}\x1b[39m${padding} ${template.slice(right)}`;
}

/** Replace emoji presentation with one-cell Nerd Font terminal glyphs. Rebuild
 * the row so changing a two-column emoji never shifts the card's right rail. */
function withTerminalIntegrationIcons(lines: string[]): string[] {
	return lines.map((line) => {
		const body = gentleCardBody(line);
		if (body?.startsWith("🧠 ")) return gentleCardRow(line, body.replace(/^🧠/, ""));
		if (body?.startsWith("🔌 ")) return gentleCardRow(line, body.replace(/^🔌/, ""));
		return line;
	});
}

/**
 * One ten-cell layered meter. The large outer parallelogram drains from sky to
 * neutral according to weekly quota, the centered white fill drains according
 * to the five-hour quota, and the monthly pool is a yellow baseline. A fully
 * exhausted/disabled weekly pool replaces the whole outer layer with red.
 */
function layeredQuotaMeter(
	fiveHour: number,
	weekly: number | undefined,
	monthly: number | undefined = undefined,
	weeklyAsAvailability = false,
): string {
	const cells = 10;
	const fiveHourCells = Math.round(fiveHour * cells);
	const weeklyDisabled = weekly === undefined || weekly <= 0;
	const monthlyCells = monthly === undefined ? 0 : Math.round(monthly * cells);
	// Keep one visible celeste cell for a non-zero weekly pool; otherwise a
	// small but real weekly allowance would be indistinguishable from no pool.
	const weeklyCells = weeklyDisabled ? cells : Math.max(1, Math.round(weekly * cells));
	let meter = "";

	for (let index = 0; index < cells; index++) {
		const topFilled = index < fiveHourCells;
		const lowerWeekly = index < weeklyCells;
		const lowerMonthly = index < monthlyCells;
		const outer: QuotaOuterState = weeklyDisabled ? "red" : lowerWeekly ? "sky" : "dim";
		const sprite = quotaLayerSprite(outer, topFilled, lowerMonthly);
		if (sprite) {
			// One grapheme, one terminal column, two raster layers in the same pixels.
			meter += sprite;
			continue;
		}
		const underline = lowerMonthly ? `${UNDERLINE_ON}${MONTHLY_YELLOW_UNDERLINE}` : "";
		const resetUnderline = lowerMonthly ? `${RESET_UNDERLINE}${RESET_UNDERLINE_COLOR}` : "";
		if (topFilled && lowerWeekly) {
			const background = weeklyDisabled ? WEEKLY_OUTER_RED_BACKGROUND : WEEKLY_SKY_BACKGROUND;
			meter += `${underline}${BRIGHT_TEXT}${background}▱${RESET_BACKGROUND}${resetUnderline}`;
		} else if (topFilled) {
			meter += `${underline}${BRIGHT_TEXT}▱${resetUnderline}`;
		} else if (lowerWeekly) {
			meter += weeklyDisabled
				? `${underline}${WEEKLY_OUTER_RED}▱${resetUnderline}`
				: `${underline}${WEEKLY_SKY}▱${resetUnderline}`;
		} else {
			meter += `${underline}${METER_EMPTY}▱${resetUnderline}`;
		}
	}

	const weeklyText = weeklyDisabled
		? `${DISABLED_RED}sem —`
		: weeklyAsAvailability
			? `${WEEKLY_SKY}sem ✓`
			: `${WEEKLY_SKY}sem ${Math.round(weekly * 100)}%`;
	return `${meter}\x1b[39m ${Math.round(fiveHour * 100)}% ${weeklyText}\x1b[39m`;
}

function antigravityUsageMeter(usage: AntigravityUsageSnapshot): string {
	if (usage.status === "ready") {
		const meter = layeredQuotaMeter(usage.remainingFraction, usage.weeklyRemainingFraction, undefined, true);
		if (usage.weeklyRemainingFraction === undefined || usage.weeklyRemainingFraction > 0 || usage.weeklyResetAt === undefined) {
			return meter;
		}
		const millisecondsLeft = usage.weeklyResetAt - Date.now();
		const resetLabel = millisecondsLeft <= 0
			? "ahora"
			: `${Math.max(1, Math.ceil(millisecondsLeft / 3_600_000))}h`;
		return `${meter} ${DISABLED_RED}${resetLabel}\x1b[39m`;
	}
	return usage.status === "loading" ? "consultando cuota real…"
		: usage.status === "unavailable" ? "cuota no disponible"
			: "esperando la primera lectura";
}

function openCodeGoUsageMeter(usage: OpenCodeGoUsageSnapshot): string {
	if (usage.status === "ready") {
		return layeredQuotaMeter(usage.remainingFraction, usage.weeklyRemainingFraction, usage.monthlyRemainingFraction);
	}
	return usage.status === "loading" ? "consultando cuota real…"
		: usage.status === "unavailable" ? "cuota no disponible"
			: "esperando la primera lectura";
}

function commandCodeUsageMeter(usage: CommandCodeUsageSnapshot): string {
	if (usage.status === "ready") {
		return layeredQuotaMeter(usage.remainingFraction, usage.weeklyRemainingFraction, usage.creditRemainingFraction);
	}
	return usage.status === "loading" ? "consultando cuota real…"
		: usage.status === "unavailable" ? "cuota no disponible"
			: "esperando la primera lectura";
}

function codexUsagePercent(text: string | undefined): number | undefined {
	if (!text) return undefined;
	const percentages = [...text.replace(TERMINAL_CONTROL_RE, "").matchAll(/(\d+(?:\.\d+)?)%/g)];
	const value = Number.parseFloat(percentages.at(-1)?.[1] ?? "");
	return Number.isFinite(value) && value >= 0 && value <= 100 ? value : undefined;
}

function cachedCodexUsageMeter(usedPercent: number): string {
	const cells = 8;
	const filled = Math.max(0, Math.min(cells, Math.round((usedPercent / 100) * cells)));
	return `${transcriptTone("warning", "▰".repeat(filled))}${transcriptTone("dim", "▱".repeat(cells - filled))} ${transcriptTone("text", `${Math.round(usedPercent)}%`)}`;
}

/** Keep metadata labels at the left and use the complete card width to align
 * their values against the right padding throughout the Status card. */
function sidebarFieldRow(template: string, label: string, value: string): string {
	const left = template.indexOf("│");
	const right = template.lastIndexOf("│");
	if (left < 0 || right <= left) return `${label} ${value}`;
	const usableWidth = Math.max(0, displayWidth(template.slice(left + 1, right)) - 2);
	const gap = Math.max(1, usableWidth - displayWidth(label) - displayWidth(value));
	return `${label}${" ".repeat(gap)}${value}`;
}

/** Gentle renders Project as a heading with its path on the next row. The
 * right rail is wide enough for the useful pair, so collapse it into the same
 * compact key/value grammar used by Branch and Session. */
function withInlineProjectFields(lines: string[]): string[] {
	const project = lines.findIndex((line) => gentleCardBody(line) === "Project");
	if (project < 0 || project + 1 >= lines.length) return lines;
	const path = gentleCardBody(lines[project + 1]!);
	if (!path) return lines;

	const compact = [...lines];
	compact[project] = gentleCardRow(lines[project]!, sidebarFieldRow(lines[project]!, "Project", path));
	compact.splice(project + 1, 1);
	for (let index = project + 1; index < compact.length; index++) {
		const body = gentleCardBody(compact[index]!);
		if (body === "") break;
		const field = body?.match(/^(Branch|Session)\s+(.+)$/);
		if (field) compact[index] = gentleCardRow(compact[index]!, sidebarFieldRow(compact[index]!, field[1]!, field[2]!));
	}
	return compact;
}

interface SidebarChangesSummary {
	files: number;
	added: number;
	deleted: number;
}

/** Pull the standalone Changes card out of the rail. Its summary is folded
 * into Usage below; /gentle:changes and its shortcut remain fully available. */
function detachGentleChangesCard(lines: string[]): { lines: string[]; summary?: SidebarChangesSummary } {
	const start = lines.findIndex((line) => {
		const plain = line.replace(TERMINAL_CONTROL_RE, "");
		return plain.includes("╭") && /\bChanges\b/.test(plain);
	});
	if (start < 0) return { lines };

	let end = start;
	while (end < lines.length && !lines[end]!.replace(TERMINAL_CONTROL_RE, "").includes("╰")) end++;
	if (end >= lines.length) return { lines };

	let summary: SidebarChangesSummary | undefined;
	for (const line of lines.slice(start + 1, end)) {
		const body = gentleCardBody(line);
		const match = body?.match(/^(\d+)\s+files?\s*·\s*\+(\d+)\s+[−-](\d+)$/i);
		if (!match) continue;
		summary = { files: Number(match[1]), added: Number(match[2]), deleted: Number(match[3]) };
		break;
	}
	if (!summary) return { lines };

	// Consume the separator before this card. If another rail section follows,
	// its own separator remains and keeps Status visually distinct from it.
	const removeFrom = start > 0 && isOnlyWhitespace(lines[start - 1]!) ? start - 1 : start;
	return { lines: [...lines.slice(0, removeFrom), ...lines.slice(end + 1)], summary };
}

/**
 * Gentle's existing Usage group describes the active Codex provider but does
 * not name it as GPT. Keep its live Codex meter, then add Antigravity A's
 * separate five-hour pool. This is a render-only patch: Gentle still owns its
 * card, cache, accent and Codex usage collection.
 */
function withSeparatedUsage(lines: string[], changes?: SidebarChangesSummary): string[] {
	const usageTitle = lines.findIndex((line) => gentleCardBody(line) === "Usage");
	if (usageTitle < 0) return lines;

	const bodyStart = usageTitle + 1;
	let bodyEnd = bodyStart;
	while (bodyEnd < lines.length && gentleCardBody(lines[bodyEnd]) !== "") bodyEnd++;
	if (bodyEnd === bodyStart) return lines;

	const currentBody = lines.slice(bodyStart, bodyEnd);
	const text = currentBody.map((line) => gentleCardBody(line) ?? "");
	const cost = text.find((line) => /^Cost\b/i.test(line))?.replace(/^Cost\s*/i, "") ?? "—";
	const codexMeter = text.find((line) => /\b(?:codex|week|5h|7d)\b/i.test(line));
	const observedCodexPercent = codexUsagePercent(codexMeter);
	if (observedCodexPercent !== undefined) observeCodexUsage(observedCodexPercent);
	const cachedCodex = codexUsageSnapshot();
	const codexValue = codexMeter?.replace(/^codex\s+week\s*/i, "")
		?? (cachedCodex.status === "ready" ? cachedCodexUsageMeter(cachedCodex.usedPercent) : "—");
	const openCodeGo = openCodeGoUsageMeter(openCodeGoUsageSnapshot());
	const commandCode = commandCodeUsageMeter(commandCodeUsageSnapshot());
	const antigravityA = antigravityUsageMeter(antigravityAUsageSnapshot());
	const antigravityB = antigravityUsageMeter(antigravityBUsageSnapshot());
	const template = currentBody[0]!;
	const providerGroups = [
		["GPT / Codex", `Cost ${cost}`, "Semana", codexValue],
		["OpenCode Go", "5 h / sem / mes", "Restante", openCodeGo],
		["Command Code", "5 h / sem / créditos", "Restante", commandCode],
		["Antigravity A", "5 h sobre semanal", "Restante", antigravityA],
		["Antigravity B", "5 h sobre semanal", "Restante", antigravityB],
	] as const;
	const replacement = providerGroups.flatMap(([provider, limit, meterLabel, meter], index) => [
		gentleCardRow(template, sidebarFieldRow(template, transcriptTone("borderAccent", provider), limit)),
		gentleCardRow(template, sidebarFieldRow(template, `  ${meterLabel}`, meter)),
		...(index < providerGroups.length - 1 ? [gentleCardRow(template, "")] : []),
	]);
	const changesRows = changes ? [
		gentleCardRow(
			template,
			sidebarFieldRow(
				template,
				"Changes",
				`${changes.files} ${changes.files === 1 ? "file" : "files"} · ${transcriptTone("success", `+${changes.added}`)} ${transcriptTone("error", `−${changes.deleted}`)}`,
			),
		),
		gentleCardRow(template, ""),
	] : [];
	return [
		...lines.slice(0, usageTitle),
		...changesRows,
		lines[usageTitle]!,
		...replacement,
		...lines.slice(bodyEnd),
	];
}

/** Apply both rail compactions atomically: never remove Changes unless a
 * usable Usage group exists to receive the summary. */
function withCompactGentleSidebar(lines: string[]): string[] {
	const project = withInlineProjectFields(lines);
	const detached = detachGentleChangesCard(project);
	const merged = withSeparatedUsage(detached.lines, detached.summary);
	return detached.summary && merged === detached.lines ? project : merged;
}

/** Gentle reserves one padding column on each side of every rail section.
 * Consume those two columns inside framed cards so their backgrounds and
 * borders span the complete content track up to the native scrollbar. */
function stretchGentleRailCards(lines: string[]): string[] {
	return lines.map((line) => {
		if (!line.startsWith(" ") || !line.endsWith(" ")) return line;
		const plain = line.replace(TERMINAL_CONTROL_RE, "");
		if (!/^ [╭│╰].*[╮│╯] $/.test(plain)) return line;

		const card = line.slice(1, -1);
		const plainCard = card.replace(TERMINAL_CONTROL_RE, "");
		const right = Math.max(plainCard.lastIndexOf("╮"), plainCard.lastIndexOf("│"), plainCard.lastIndexOf("╯"));
		if (right <= 0) return line;
		const rawRight = rawOffsetForPlainOffset(card, right);
		const fill = plainCard.startsWith("│") ? "  " : "──";
		return `${card.slice(0, rawRight)}${fill}${card.slice(rawRight)}`;
	});
}

type LayoutNodeLike = {
	type?: unknown;
	gap?: unknown;
	entries?: Array<{
		basis?: unknown;
		component?: unknown;
		grow?: unknown;
		shrink?: unknown;
		minSize?: unknown;
	}>;
};

type GentleRailLayoutStabilizer = {
	revision: number;
	base: () => LayoutNodeLike;
	wrapper: () => LayoutNodeLike;
};

type RenderableComponent = Record<symbol, unknown> & {
	render?: (width: number) => string[];
	invalidate?: () => void;
	children?: unknown[];
};

type ScrollViewRestoreLike = Record<symbol, unknown> & {
	scrollbar?: unknown;
	setScrollbar?: (mode: "hidden" | "auto" | "always") => void;
};

type ScrollViewGutterLike = ScrollViewRestoreLike & {
	getContentWidth?: (width: number) => number;
};

// Gentle separates Pi's transcript and its 50-column rail with a three-column
// hstack gap. Removing that gap grows the native transcript ScrollView by the
// same three columns; reserving them from its content keeps every message at
// its original width while moving only Pi's own thumb to the rail edge.
const GENTLE_TRANSCRIPT_GUTTER_COLUMNS = 3;

function compactGentleRailGap(node: LayoutNodeLike): boolean {
	const hasRail = node.type === "hstack" && node.entries?.some(
		(candidate) => candidate.basis === 50 && candidate.component !== undefined,
	);
	if (!hasRail || node.gap === 0) return false;
	// The rail keeps its exact x-coordinate: the three columns formerly spent
	// as gap now belong to the left ScrollView. Its content width is reduced by
	// those same columns below, so only the native scrollbar moves.
	node.gap = 0;
	return true;
}

function isGentleRailLayout(node: LayoutNodeLike): boolean {
	return node.type === "hstack" && node.entries?.some(
		(candidate) => candidate.basis === 50 && candidate.component !== undefined,
	) === true;
}

/**
 * Normalize Gentle's generated hstack before pi-tui measures or paints it.
 *
 * Gentle creates a fresh `{ gap: 3 }` layout node whenever the rail scrollTop
 * changes.  Doing the correction later from the rail child's render() lets one
 * frame use the old three-column gap, then schedules a second corrected frame;
 * token streaming makes that look like the transcript rail is blinking left.
 * Wrapping the root layout hook means every fresh node reaches the compositor
 * already normalized, so no intermediate geometry can be displayed.
 */
function stabilizeGentleRailLayout(ui: unknown): (() => LayoutNodeLike) | undefined {
	const tui = ui as { layoutRoot?: Record<symbol, unknown> } | undefined;
	const root = tui?.layoutRoot;
	const current = root?.[LAYOUT_NODE];
	if (!root || typeof current !== "function") return undefined;

	const previous = root[GENTLE_RAIL_LAYOUT_STABILIZER] as GentleRailLayoutStabilizer | undefined;
	if (previous?.revision === 1 && current === previous.wrapper) return previous.wrapper;

	// If this is a newer live revision, unwrap our previous decorator. If
	// Gentle replaced the hook in the meantime, the current hook is the new base.
	const base = previous && current === previous.wrapper ? previous.base : current as () => LayoutNodeLike;
	const wrapper = function ccUiStableGentleRailLayout(this: unknown): LayoutNodeLike {
		const node = base.call(this);
		const active = isGentleRailLayout(node);
		configureNativeTranscriptGutter(ui, active);
		if (active) compactGentleRailGap(node);
		return node;
	};
	root[GENTLE_RAIL_LAYOUT_STABILIZER] = { revision: 1, base, wrapper } satisfies GentleRailLayoutStabilizer;
	root[LAYOUT_NODE] = wrapper;
	return wrapper;
}

/**
 * Give Gentle its exact replacement hook back before its footer dispose runs.
 * Its cleanup intentionally uses identity (`root[NODE] === replacement`), so
 * leaving our decorator installed would make /reload retain the old sidebar.
 *
 * `peelDetached` handles the one-time upgrade from the previous live revision:
 * that revision may already have missed Gentle's dispose before this newer
 * wrapper was loaded. Gentle's left entry exposes the underlying root layout,
 * allowing us to remove that single orphaned rail layer safely.
 */
function restoreGentleRailLayoutHook(ui: unknown, peelDetached: boolean): void {
	const root = (ui as { layoutRoot?: Record<symbol, unknown> } | undefined)?.layoutRoot;
	if (!root) return;
	const state = root[GENTLE_RAIL_LAYOUT_STABILIZER] as GentleRailLayoutStabilizer | undefined;
	if (!state || root[LAYOUT_NODE] !== state.wrapper) return;

	root[LAYOUT_NODE] = state.base;
	Reflect.deleteProperty(root, GENTLE_RAIL_LAYOUT_STABILIZER);
	if (!peelDetached) return;

	try {
		const node = state.base.call(root);
		if (!isGentleRailLayout(node)) return;
		const left = node.entries?.find((entry) => entry.basis === 0 && entry.component !== undefined)?.component as
			Record<symbol, unknown> | undefined;
		const underlying = left?.[LAYOUT_NODE];
		if (typeof underlying === "function") root[LAYOUT_NODE] = underlying;
	} catch {
		// A stale/disposed Gentle closure can fail while being inspected. Keeping
		// its base hook is still safer than retaining our decorator around it.
	}
}

function configureNativeTranscriptGutter(ui: unknown, active: boolean): void {
	try {
		const transcript = (ui as { getPrimaryScrollView?: () => unknown })
			.getPrimaryScrollView?.() as ScrollViewGutterLike | undefined;
		if (!transcript || typeof transcript.getContentWidth !== "function") return;

		let base = transcript[GENTLE_TRANSCRIPT_CONTENT_WIDTH_BASE] as
			((width: number) => number) | undefined;
		if (!base) {
			base = transcript.getContentWidth.bind(transcript);
			transcript[GENTLE_TRANSCRIPT_CONTENT_WIDTH_BASE] = base;
			transcript.getContentWidth = function ccUiTranscriptContentWidth(width: number): number {
				const original = this[GENTLE_TRANSCRIPT_CONTENT_WIDTH_BASE] as
					((availableWidth: number) => number) | undefined;
				const enabled = this[GENTLE_TRANSCRIPT_GUTTER_ACTIVE] === true;
				return original?.(Math.max(1, width - (enabled ? GENTLE_TRANSCRIPT_GUTTER_COLUMNS : 0))) ?? width;
			};
		}
		transcript[GENTLE_TRANSCRIPT_GUTTER_ACTIVE] = active;
	} catch {
		// Never let a closing/reloaded TUI affect the transcript's native layout.
	}
}

/** Undo the transparent rail-layout experiment from the previous live patch.
 * The marker is ours, so removing this property cannot affect Gentle's own
 * component (it has no layout node at this level). */
function removeLegacyGentleRailGutter(sidebar: RenderableComponent): void {
	if (sidebar[GENTLE_RAIL_GUTTER_LAYOUT] === undefined) return;
	Reflect.deleteProperty(sidebar, LAYOUT_NODE);
	Reflect.deleteProperty(sidebar, GENTLE_RAIL_GUTTER_LAYOUT);
}

/** Restore the native transcript scrollbar if a previous live revision hid it
 * while trying an experimental relocation. This is intentionally one-way: the
 * current patch never draws or moves a synthetic thumb. */
function restoreNativeTranscriptScrollbar(ui: unknown): void {
	try {
		const transcript = (ui as { getPrimaryScrollView?: () => unknown })
			.getPrimaryScrollView?.() as ScrollViewRestoreLike | undefined;
		const previousMode = transcript?.[GENTLE_TRANSCRIPT_SCROLLBAR_MODE];
		if ((previousMode === "auto" || previousMode === "always") && transcript?.scrollbar === "hidden") {
			transcript.setScrollbar?.(previousMode);
		}
		if (transcript && previousMode !== undefined) {
			Reflect.deleteProperty(transcript, GENTLE_TRANSCRIPT_SCROLLBAR_MODE);
		}
	} catch {
		// The UI may be mid-reload; its normal scrollbar setting remains untouched.
	}
}

/**
 * Gentle creates a ScrollView inside its own closure. Pi's layout engine
 * renders the ScrollView's child directly (rather than ScrollView.render), so
 * patch that child from the fixed 50-column hstack entry. This changes only
 * the ornamental row, never Gentle's state, theme, cards, or layout logic.
 */
function hideGentleSidebarBanner(ui: unknown): boolean {
	const tui = ui as { layoutRoot?: Record<symbol, unknown> } | undefined;
	const root = tui?.layoutRoot;
	const layout = stabilizeGentleRailLayout(ui);
	if (typeof layout !== "function") return false;

	try {
		const node = layout.call(root);
		const entry = node.type === "hstack"
			? node.entries?.find((candidate) => candidate.basis === 50 && candidate.component !== undefined)
			: undefined;
		const scroll = entry?.component as (RenderableComponent & {
			getContentWidth?: (width: number) => number;
		}) | undefined;
		const sidebar = scroll?.children?.[0] as RenderableComponent | undefined;
		if (!sidebar || typeof sidebar.render !== "function") {
			configureNativeTranscriptGutter(ui, false);
			return false;
		}

		const originalRender = sidebar[GENTLE_SIDEBAR_RENDER_BASE] as RenderableComponent["render"] | undefined ?? sidebar.render;
		sidebar[GENTLE_SIDEBAR_RENDER_BASE] = originalRender;
		sidebar.render = function ccUiWithoutGentleSidebarBanner(width: number): string[] {
			restoreNativeTranscriptScrollbar(ui);
			// Re-read through the stabilized root hook so a root/session transition
			// also updates the transcript gutter. Geometry is already normalized
			// before this child render; never request a corrective second frame here.
			try {
				const current = layout.call(root);
				const active = isGentleRailLayout(current);
				removeLegacyGentleRailGutter(sidebar);
				configureNativeTranscriptGutter(ui, active);
			} catch {
				configureNativeTranscriptGutter(ui, false);
				// If Gentleman has disposed this rail, leave its native cleanup alone.
			}
			const lines = originalRender.call(this, width);
			return withTerminalIntegrationIcons(
				withCompactGentleSidebar(
					withoutGentleSidebarFallbackSummary(
						withoutGentleSidebarRuntimeDetails(
							stretchGentleRailCards(withoutGentleSidebarBanner(lines)),
						),
					),
				),
			);
		};

		restoreNativeTranscriptScrollbar(ui);
		removeLegacyGentleRailGutter(sidebar);
		const active = isGentleRailLayout(node);
		configureNativeTranscriptGutter(ui, active);
		return true;
	} catch {
		// The rail is experimental upstream UI. If it is unavailable, leave it
		// alone rather than affecting Pi's normal layout.
		return false;
	}
}

type GentleSidebarState = {
	active?: boolean;
	ownsHost?: () => boolean;
};

/**
 * In fullscreen Gentleman suppresses its normal bottom bar because the same
 * values used to be duplicated in the Status card. We remove that duplication
 * above, then temporarily lower the rail's suppress flag while its existing
 * footer renders. This preserves Gentle's live model/context renderer without
 * importing or editing any of its private source.
 */
function restoreGentleStatusLine(host: unknown): boolean {
	const mode = host as {
		customFooter?: RenderableComponent;
		ui?: { terminal?: Record<symbol, unknown>; requestRender?: () => void };
	};
	const footer = mode.customFooter;
	const state = mode.ui?.terminal?.[GENTLE_SIDEBAR_STATE] as GentleSidebarState | undefined;
	if (!footer || typeof footer.render !== "function" || !state) return false;

	const originalRender = footer[GENTLE_FOOTER_RENDER_BASE] as RenderableComponent["render"] | undefined ?? footer.render;
	footer[GENTLE_FOOTER_RENDER_BASE] = originalRender;
	footer.render = function ccUiGentleStatusLine(width: number): string[] {
		if (!state.active || !state.ownsHost?.()) return originalRender.call(this, width);
		const active = state.active;
		state.active = false;
		try {
			return stretchGentleStatusLine(
				withoutGentleStatusLocation(withoutGentleStatusBrand(originalRender.call(this, width))),
				width,
			);
		} finally {
			state.active = active;
		}
	};
	mode.ui?.requestRender?.();
	return true;
}

/**
 * The extension footer is installed before Pi has necessarily selected its
 * fullscreen layout. Retry briefly: the first valid hstack is the one that
 * owns Gentle's 50-column rail. This is why a one-shot inspection missed the
 * banner even though the sidebar later appeared.
 */
function scheduleGentleSidebarBannerRemoval(ui: unknown): void {
	const requestRender = () => (ui as { requestRender?: () => void } | undefined)?.requestRender?.();
	// The rail's first layout may replace its generated hstack after the
	// transcript obtains its initial scroll position. Reapply the *same* local
	// decoration during that bounded settling window; this is not a watcher and
	// it leaves Gentle's source and later lifecycle untouched.
	let attemptsLeft = 20;
	const retry = () => {
		if (hideGentleSidebarBanner(ui)) {
			requestRender();
		}
		if (--attemptsLeft <= 0) return;
		const timer = setTimeout(retry, 50);
		timer.unref();
	};
	retry();
}

/** Keep normal assistant prose readable over a transparent terminal. */
function brightenResponse(line: string): string {
	return `${BRIGHT_TEXT}${line.replace(RESET_FOREGROUND_RE, BRIGHT_TEXT)}\x1b[39m`;
}

// Matches the animation ring in fast-mode-indicator.ts. Its phase advances
// with the same 120ms clock as the live status rail.
const FAST_RGB: ReadonlyArray<readonly [number, number, number]> = [
	[255, 78, 183],
	[187, 91, 255],
	[73, 160, 255],
	[66, 225, 211],
	[145, 238, 91],
	[255, 211, 70],
	[255, 128, 78],
];

function fastRgb(index: number): string {
	const [r, g, b] = FAST_RGB[index % FAST_RGB.length]!;
	return `\x1b[38;2;${r};${g};${b}m`;
}

function rainbowFrame(text: string, phase = 0): string {
	return [...text].map((character, index) => `${fastRgb(index + phase)}${character}`).join("") + "\x1b[39m";
}

type SemanticToolResult = {
	content?: Array<{ type?: unknown; text?: unknown }>;
	details?: unknown;
	isError?: unknown;
};

function toolFrameLabel(toolName: unknown, args: unknown, result?: SemanticToolResult): string {
	if (toolName === "ask_user_question") {
		const details = result?.details as { cancelled?: unknown } | undefined;
		if (result?.isError === true) return "Pregunta · error";
		if (details?.cancelled === true) return "Pregunta cancelada";
		return result ? "Respuesta de loonbac" : "Pregunta para loonbac";
	}
	if (toolName === "todo") {
		const action = typeof args === "object" && args !== null
			? (args as { action?: unknown }).action
			: undefined;
		return action === "write" && result ? "Tareas · actualizadas" : "Tareas";
	}
	if (toolName !== "subagent_run" || typeof args !== "object" || args === null) return "Comando";
	const values = args as { agent?: unknown; label?: unknown };
	const detail = typeof values.label === "string" && values.label.trim() !== ""
		? values.label.trim()
		: typeof values.agent === "string" && values.agent.trim() !== ""
			? values.agent.trim()
			: undefined;
	return detail ? `Agente · ${detail}` : "Agente";
}

function wrappedSemanticRows(text: string, width: number, prefix = ""): string[] {
	const normalized = text.replace(/\s+/gu, " ").trim();
	if (normalized === "") return [];
	const prefixWidth = displayWidth(prefix);
	const wrapped = wrapTextWithAnsi(normalized, Math.max(1, width - prefixWidth));
	const continuation = " ".repeat(prefixWidth);
	return wrapped.map((line, index) => `${index === 0 ? prefix : continuation}${line}`);
}

function semanticQuestionBody(args: unknown, result: SemanticToolResult | undefined, width: number): string[] {
	const details = result?.details as {
		answers?: Array<{ question?: unknown; answer?: unknown; selected?: unknown }>;
		cancelled?: unknown;
	} | undefined;
	if (details?.cancelled === true) return [transcriptTone("muted", "La pregunta fue cancelada.")];

	const answers = Array.isArray(details?.answers) ? details.answers : [];
	if (answers.length > 0) {
		const lines: string[] = [];
		answers.forEach((entry, index) => {
			const question = typeof entry.question === "string" ? entry.question : `Pregunta ${index + 1}`;
			const selected = Array.isArray(entry.selected)
				? entry.selected.filter((value): value is string => typeof value === "string").join(", ")
				: "";
			const answer = typeof entry.answer === "string" && entry.answer.trim() !== ""
				? entry.answer
				: selected || "Sin respuesta";
			if (index > 0) lines.push("");
			lines.push(...wrappedSemanticRows(question, width, answers.length > 1 ? `${index + 1}. ` : "" )
				.map((line) => transcriptTone("muted", line)));
			lines.push(...wrappedSemanticRows(answer, width, "↳ ")
				.map((line) => `${BRIGHT_TEXT}${line}\x1b[39m`));
		});
		return lines;
	}

	const questions = typeof args === "object" && args !== null && Array.isArray((args as { questions?: unknown }).questions)
		? (args as { questions: Array<{ question?: unknown }> }).questions
		: [];
	const lines = questions.flatMap((entry, index) => {
		const question = typeof entry.question === "string" ? entry.question : `Pregunta ${index + 1}`;
		return wrappedSemanticRows(question, width, questions.length > 1 ? `${index + 1}. ` : "")
			.map((line) => `${BRIGHT_TEXT}${line}\x1b[39m`);
	});
	if (!result && lines.length > 0) lines.push(transcriptTone("muted", "Esperando tu respuesta…"));
	return lines;
}

function semanticTodoBody(args: unknown, result: SemanticToolResult | undefined, width: number): string[] | undefined {
	const details = result?.details as { gentleTodo?: { tasks?: unknown } } | undefined;
	const resultTasks = details?.gentleTodo?.tasks;
	const argTasks = typeof args === "object" && args !== null ? (args as { tasks?: unknown }).tasks : undefined;
	const tasks = Array.isArray(resultTasks) ? resultTasks : Array.isArray(argTasks) ? argTasks : undefined;
	if (!tasks) return undefined;

	const statuses = tasks.map((task) => typeof task === "object" && task !== null
		? (task as { status?: unknown }).status
		: undefined);
	const done = statuses.filter((status) => status === "done").length;
	const active = statuses.filter((status) => status === "in_progress").length;
	const pending = Math.max(0, tasks.length - done - active);
	const plural = (count: number, singular: string, multiple: string) => `${count} ${count === 1 ? singular : multiple}`;
	const summary = [
		plural(tasks.length, "tarea", "tareas"),
		transcriptTone("success", `✓ ${plural(done, "completada", "completadas")}`),
		transcriptTone("warning", `◐ ${plural(active, "en curso", "en curso")}`),
		transcriptTone("muted", `○ ${plural(pending, "pendiente", "pendientes")}`),
	].join("  ·  ");
	return wrapTextWithAnsi(summary, Math.max(1, width));
}

function semanticToolBody(
	toolName: unknown,
	args: unknown,
	result: SemanticToolResult | undefined,
	width: number,
): string[] | undefined {
	if (toolName === "ask_user_question") return semanticQuestionBody(args, result, width);
	if (toolName === "todo") return semanticTodoBody(args, result, width);
	return undefined;
}

/** Frame a transcript item without consuming space from Pi's viewport. */
function frame(lines: string[], width: number, label: string, rainbow = false): string[] {
	let first = 0;
	let last = lines.length;
	while (first < last && isOnlyWhitespace(lines[first]!)) first++;
	while (last > first && isOnlyWhitespace(lines[last - 1]!)) last--;
	const body = lines.slice(first, last);
	if (body.length === 0 || width < 16) return body;

	const contentWidth = Math.max(1, width - 4);
	const borderWidth = Math.max(1, width - 2);
	const shownLabel = clipPlainText(label, Math.max(1, borderWidth - 3));
	const title = `─ ${shownLabel} `;
	const topFill = Math.max(0, borderWidth - displayWidth(title));
	const phase = rainbow ? fastModeAnimationPhase() : 0;
	const content = body.map((rawLine, row) => {
		const line = label === "Respuesta" ? brightenResponse(rawLine) : rawLine;
		const padding = Math.max(0, contentWidth - displayWidth(line));
		if (!rainbow) return `│ ${line}${" ".repeat(padding)} │`;
		return `${rainbowFrame("│", phase + row + 1)} ${line}${" ".repeat(padding)} ${rainbowFrame("│", phase + row + 4)}`;
	});
	const top = `┌${title}${"─".repeat(topFill)}┐`;
	const bottom = `└${"─".repeat(borderWidth)}┘`;
	return [
		rainbow ? rainbowFrame(top, phase) : top,
		...content,
		rainbow ? rainbowFrame(bottom, phase + 3) : bottom,
	];
}

function transcriptTone(role: string, text: string): string {
	try {
		const activeTheme = transcriptTheme
			?? sharedHostState[TRANSCRIPT_THEME] as TranscriptTheme | undefined;
		if (activeTheme !== undefined) transcriptTheme = activeTheme;
		return activeTheme?.fg?.(role, text) ?? text;
	} catch {
		return text;
	}
}

/** Render the user's message as a compact palette-aware transcript card. */
function frameUserMessage(lines: string[], width: number): string[] {
	const cleaned = lines.map((line) => line
		.replace(OSC133_ZONE_RE, "")
		.replace(USER_MESSAGE_BACKGROUND_RE, ""));
	let first = 0;
	let last = cleaned.length;
	while (first < last && isOnlyWhitespace(cleaned[first]!)) first++;
	while (last > first && isOnlyWhitespace(cleaned[last - 1]!)) last--;
	const body = cleaned.slice(first, last);
	if (body.length === 0 || width < 16) return body;

	const border = (text: string) => transcriptTone("borderAccent", text);
	const label = (text: string) => transcriptTone("claudeShimmer", text);
	const contentWidth = Math.max(1, width - 4);
	const borderWidth = Math.max(1, width - 2);
	const titlePrefix = "─ ";
	const titleSuffix = " ";
	const titleWidth = displayWidth(titlePrefix) + displayWidth("loonbac") + displayWidth(titleSuffix);
	const topFill = Math.max(0, borderWidth - titleWidth);
	const content = body.map((line) => {
		const padding = Math.max(0, contentWidth - displayWidth(line));
		return `${border("│")} ${line}${" ".repeat(padding)} ${border("│")}`;
	});
	const top = `${border(`┌${titlePrefix}`)}${label("loonbac")}${border(`${titleSuffix}${"─".repeat(topFill)}┐`)}`;
	const bottom = border(`└${"─".repeat(borderWidth)}┘`);
	return [
		OSC133_ZONE_START + top,
		...content,
		OSC133_ZONE_END + OSC133_ZONE_FINAL + bottom,
	];
}

function isResponseCreatedWhileFastWasActive(message: unknown): boolean {
	const activatedAt = fastModeActivatedAt();
	const timestamp = (message as { timestamp?: unknown } | undefined)?.timestamp;
	return typeof activatedAt === "number" && typeof timestamp === "number" && timestamp >= activatedAt;
}

/**
 * Pi's stock UserMessage Box paints to the full transcript width, even for a
 * one-word message. In fullscreen that reads as a giant slab reaching toward
 * the rail. Render it once to learn its actual markdown width, then render it
 * at that compact width so Pi keeps its own OSC copy zones and wrapping.
 */
function compactUserMessageWidth(lines: string[], availableWidth: number): number {
	let widest = 0;
	for (const line of lines) {
		const content = stripTerminalSequences(line).trimEnd();
		if (content.length > 0) widest = Math.max(widest, visibleWidth(content));
	}
	// Preserve the Box's trailing one-column breathing room after the text.
	return Math.max(3, Math.min(availableWidth, widest + 1));
}

/** The exact host notice dropped by patch 2 (interactive-mode.js setToolsExpanded). */
const TOOL_OUTPUT_STATUS_RE = /^Tool output: (?:expanded|collapsed)$/;

export function installHostPatches(): void {
	installQuotaSpritePersistence();
	prepareQuotaMeterSprites();
	// /resume: replace the easy-to-trigger Ctrl+D confirmation with a
	// deliberate hold-Delete gesture that fills the blue selection red.
	// buildBaseLayout is called from SessionSelectorComponent's constructor,
	// after its private list/header fields exist and before the first render.
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const sessionSelectorProto = SessionSelectorComponent.prototype as any;
	if (typeof sessionSelectorProto.buildBaseLayout === "function") {
		const originalBuildBaseLayout = sessionSelectorProto[SESSION_SELECTOR_LAYOUT_BASE]
			?? sessionSelectorProto.buildBaseLayout;
		sessionSelectorProto[SESSION_SELECTOR_LAYOUT_BASE] = originalBuildBaseLayout;
		sessionSelectorProto.buildBaseLayout = function ccUiResumeDeleteHold(...args: unknown[]): unknown {
			decorateResumeSelector(this as PatchedSessionSelector);
			return originalBuildBaseLayout.apply(this, args);
		};
	}
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const amProto = AssistantMessageComponent.prototype as any;
	if (!amProto[BLANK_RENDER_FLAG] && typeof amProto.render === "function") {
		const originalRender = amProto.render;
		amProto.render = function ccUiBlankMessageRender(width: number): string[] {
			const lines = originalRender.call(this, width);
			if (!Array.isArray(lines) || lines.length === 0) return lines;
			let blank = 0;
			while (blank < lines.length && isBlankRow(lines[blank])) blank++;
			if (blank === lines.length) return [];
			// (b) collapse a run of leading blank rows to one; keep lines[0] — it
			// may carry the OSC133 zone-start mark.
			if (blank > 1) lines.splice(1, blank - 1);
			return lines;
		};
		amProto[BLANK_RENDER_FLAG] = true;
	}

	if (typeof amProto.updateContent === "function") {
		// Remember the mode on the component, rather than checking it during
		// render. Therefore a response begun under Fast keeps its RGB border if
		// Fast is disabled while it streams, while all older timestamps stay plain.
		const originalUpdate = amProto[ASSISTANT_UPDATE_BASE] ?? amProto.updateContent;
		amProto[ASSISTANT_UPDATE_BASE] = originalUpdate;
		amProto.updateContent = function ccUiTrackFastResponse(message: unknown, ...args: unknown[]): unknown {
			this[RESPONSE_FRAME_CACHE] = undefined;
			if (isResponseCreatedWhileFastWasActive(message)) this[FAST_RESPONSE_FRAME] = true;
			return originalUpdate.call(this, message, ...args);
		};
	}

	if (typeof amProto.render === "function") {
		// Preserve the pre-frame renderer once, then replace only this outer
		// layer on every /reload. That makes visual tweaks live without stacking
		// wrappers or forcing the user to restart Pi.
		const originalRender = amProto[RESPONSE_BASE_RENDER] ?? amProto.render;
		amProto[RESPONSE_BASE_RENDER] = originalRender;
		amProto.render = function ccUiFramedAssistantRender(width: number): string[] {
			if (width < 16) return originalRender.call(this, width);
			const rainbow = this[FAST_RESPONSE_FRAME] === true;
			const phase = rainbow ? fastModeAnimationPhase() : -1;
			const cached = this[RESPONSE_FRAME_CACHE] as TranscriptFrameCache | undefined;
			if (cached?.width === width && cached.phase === phase) return cached.lines;
			const body = cached?.width === width ? cached.body : originalRender.call(this, width - 4);
			const lines = frame(body, width, "Respuesta", rainbow);
			this[RESPONSE_FRAME_CACHE] = { width, phase, body, lines } satisfies TranscriptFrameCache;
			return lines;
		};
	}

	// User messages retain Pi's native Markdown typography and copy zones. The
	// stock full-row background is replaced by a compact wallpaper-palette card.
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const userProto = UserMessageComponent.prototype as any;
	if (typeof userProto.invalidate === "function") {
		const originalInvalidate = userProto[USER_MESSAGE_INVALIDATE_BASE] ?? userProto.invalidate;
		userProto[USER_MESSAGE_INVALIDATE_BASE] = originalInvalidate;
		userProto.invalidate = function ccUiInvalidateUserMessageCache(...args: unknown[]): unknown {
			this[USER_MESSAGE_FRAME_CACHE] = undefined;
			return originalInvalidate.apply(this, args);
		};
	}
	if (typeof userProto.render === "function") {
		const originalRender = userProto[USER_MESSAGE_BASE_RENDER] ?? userProto.render;
		userProto[USER_MESSAGE_BASE_RENDER] = originalRender;
		userProto.render = function ccUiFramedUserMessage(width: number): string[] {
			if (width < 16) return originalRender.call(this, width);
			const state = this.outputPad;
			const cached = this[USER_MESSAGE_FRAME_CACHE] as TranscriptFrameCache | undefined;
			if (cached?.width === width && cached.state === state) return cached.lines;
			const availableBodyWidth = Math.max(3, width - 4);
			const initial = originalRender.call(this, availableBodyWidth) as string[];
			const compactWidth = compactUserMessageWidth(initial, availableBodyWidth);
			const body = compactWidth < availableBodyWidth
				? originalRender.call(this, compactWidth) as string[]
				: initial;
			const panelWidth = Math.max(16, Math.min(width, compactWidth + 4));
			const lines = frameUserMessage(body, panelWidth);
			this[USER_MESSAGE_FRAME_CACHE] = { width, phase: -1, body, lines, state } satisfies TranscriptFrameCache;
			return lines;
		};
	}

	// Tool executions share one frame, but interaction/task tools receive their
	// own semantic title and body instead of being mislabeled as commands.
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const toolProto = ToolExecutionComponent.prototype as any;
	if (typeof toolProto.invalidate === "function") {
		const originalInvalidate = toolProto[TOOL_INVALIDATE_BASE] ?? toolProto.invalidate;
		toolProto[TOOL_INVALIDATE_BASE] = originalInvalidate;
		toolProto.invalidate = function ccUiInvalidateToolFrameCache(...args: unknown[]): unknown {
			this[TOOL_FRAME_CACHE] = undefined;
			return originalInvalidate.apply(this, args);
		};
	}
	if (typeof toolProto.markExecutionStarted === "function") {
		const originalStart = toolProto[TOOL_EXECUTION_START_BASE] ?? toolProto.markExecutionStarted;
		toolProto[TOOL_EXECUTION_START_BASE] = originalStart;
		toolProto.markExecutionStarted = function ccUiTrackFastToolExecution(...args: unknown[]): unknown {
			this[TOOL_FRAME_CACHE] = undefined;
			if (fastModeIsActive()) this[FAST_TOOL_FRAME] = true;
			return originalStart.call(this, ...args);
		};
	}
	const mutationBases = toolProto[TOOL_MUTATION_BASES] as Map<string, (...args: unknown[]) => unknown> | undefined
		?? new Map<string, (...args: unknown[]) => unknown>();
	toolProto[TOOL_MUTATION_BASES] = mutationBases;
	for (const method of ["updateArgs", "setArgsComplete", "updateResult", "setExpanded", "setShowImages", "setImageWidthCells"] as const) {
		if (typeof toolProto[method] !== "function") continue;
		const originalMutation = mutationBases.get(method) ?? toolProto[method];
		mutationBases.set(method, originalMutation);
		toolProto[method] = function ccUiInvalidateToolFrameOnMutation(...args: unknown[]): unknown {
			this[TOOL_FRAME_CACHE] = undefined;
			return originalMutation.apply(this, args);
		};
	}
	if (typeof toolProto.render === "function") {
		const originalRender = toolProto[TOOL_BASE_RENDER] ?? toolProto.render;
		toolProto[TOOL_BASE_RENDER] = originalRender;
		toolProto.render = function ccUiFramedToolRender(width: number): string[] {
			if (width < 16) return originalRender.call(this, width);
			const rainbow = this[FAST_TOOL_FRAME] === true;
			const phase = rainbow ? fastModeAnimationPhase() : -1;
			const result = this.result as SemanticToolResult | undefined;
			const label = toolFrameLabel(this.toolName, this.args, result);
			const imageState = this.convertedImages instanceof Map ? this.convertedImages.size : 0;
			const cached = this[TOOL_FRAME_CACHE] as TranscriptFrameCache | undefined;
			const state = `${imageState}:${label}`;
			if (cached?.width === width && cached.phase === phase && cached.state === state) return cached.lines;
			const body = cached?.width === width && cached.state === state
				? cached.body
				: semanticToolBody(this.toolName, this.args, result, width - 4)
					?? originalRender.call(this, width - 4);
			const lines = frame(body, width, label, rainbow);
			this[TOOL_FRAME_CACHE] = { width, phase, body, lines, state } satisfies TranscriptFrameCache;
			return lines;
		};
	}

	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const imProto = InteractiveMode.prototype as any;
	if (typeof imProto.setExtensionFooter === "function") {
		// Gentle installs its footer after this extension's session_start hook.
		// Capture the host then, so live wallpaper changes can invalidate its
		// terminal-owned card cache without replacing Pi's Theme proxy.
		const originalSetFooter = imProto[EXTENSION_FOOTER_BASE] ?? imProto.setExtensionFooter;
		imProto[EXTENSION_FOOTER_BASE] = originalSetFooter;
		imProto.setExtensionFooter = function ccUiSetExtensionFooter(...args: unknown[]) {
			// setExtensionFooter disposes the current footer synchronously. Restore
			// Gentle's hook first so its identity-guarded uninstall can run. If the
			// footer is already gone, peel the orphan left by the preceding live
			// revision before a new Gentle sidebar is installed.
			restoreGentleRailLayoutHook(this.ui, this.customFooter === undefined);
			(globalThis as unknown as Record<symbol, unknown>)[WALLPAPER_REDRAW] = () => {
				const terminal = this.ui?.terminal as Record<symbol, unknown> | undefined;
				const cache = terminal?.[GENTLE_SIDEBAR_CACHE] as { revision?: unknown } | undefined;
				if (typeof cache?.revision === "number") cache.revision += 1;
				this.ui?.invalidate?.();
				this.ui?.requestRender?.();
			};
			const result = originalSetFooter.apply(this, args);
			// Gentle builds the fullscreen sidebar while installing its footer. The
			// live layout now exists, so patch its rail and restore the compact
			// status line that the rail normally suppresses.
			scheduleGentleSidebarBannerRemoval(this.ui);
			restoreGentleStatusLine(this);
			return result;
		};
	}

	if (typeof imProto.createExtensionUIContext === "function") {
		// An extension UI context deliberately exposes a small public API.  It
		// does not expose redraw hooks, but its owning InteractiveMode does own
		// them.  Add narrowly-scoped hooks to the context so wallpaper-sync can
		// redraw the *existing* Theme object.  Crucially, we also bump Gentle's
		// terminal-owned sidebar revision: its card renderer memoizes rendered
		// lines, which otherwise preserves old right/bottom rails after a color
		// change.  No Gentle source is modified.
		const originalCreateContext = imProto[EXTENSION_UI_BASE] ?? imProto.createExtensionUIContext;
		imProto[EXTENSION_UI_BASE] = originalCreateContext;
		imProto.createExtensionUIContext = function ccUiExtensionContext() {
			const context = originalCreateContext.call(this) as Record<string, unknown>;
			const currentTheme = context.theme;
			if (currentTheme && typeof currentTheme === "object") {
				transcriptTheme = currentTheme as TranscriptTheme;
				sharedHostState[TRANSCRIPT_THEME] = transcriptTheme;
			}
			const originalCustom = typeof context.custom === "function"
				? context.custom as (...args: unknown[]) => unknown
				: undefined;
			const redraw = () => {
				this.ui?.invalidate?.();
				this.ui?.requestRender?.();
			};
			const invalidateSidebar = () => {
				const terminal = this.ui?.terminal as Record<symbol, unknown> | undefined;
				const cache = terminal?.[GENTLE_SIDEBAR_CACHE] as { revision?: unknown } | undefined;
				if (typeof cache?.revision === "number") cache.revision += 1;
				redraw();
			};
			Object.defineProperties(context, {
				invalidate: { value: redraw, enumerable: false },
				requestRender: { value: () => this.ui?.requestRender?.(), enumerable: false },
				invalidateSidebar: { value: invalidateSidebar, enumerable: false },
				...(originalCustom
					? {
						custom: {
							value: (factory: unknown, ...args: unknown[]) => {
								const factorySource = typeof factory === "function" ? String(factory) : "";
								const isAgentsPanel = factorySource.includes("AgentsView");
								const decoratedFactory = typeof factory === "function"
									? (...factoryArgs: unknown[]) => {
										const effectiveArgs = isAgentsPanel && factoryArgs.length > 0
											? [tuiForGentleAgentsOverlay(factoryArgs[0]), ...factoryArgs.slice(1)]
											: factoryArgs;
										return decorateGentleModelPanel(
											(factory as (...values: unknown[]) => unknown)(...effectiveArgs),
											effectiveArgs[0] as { requestRender?: () => void } | undefined,
										);
									}
									: factory;
								return originalCustom(decoratedFactory, ...patchGentleOverlayOptions(factory, args));
							},
							enumerable: true,
						},
					}
					: {}),
			});
			return context;
		};
	}

	if (!imProto[STATUS_FLAG] && typeof imProto.showStatus === "function") {
		const originalShowStatus = imProto.showStatus;
		imProto.showStatus = function ccUiFilteredShowStatus(message: unknown): unknown {
			if (typeof message === "string" && TOOL_OUTPUT_STATUS_RE.test(message)) return undefined;
			return originalShowStatus.call(this, message);
		};
		imProto[STATUS_FLAG] = true;
	}

	// Patch 3 — Drop rogue terminal screen clear sequences (\x1b[2J\x1b[3J\x1b[H) emitted by third-party startup banners
	const STDOUT_FLAG = Symbol.for("better-cc-ui:filtered-stdout-clear");
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const pStdout = process.stdout as any;
	if (!pStdout[STDOUT_FLAG] && typeof process.stdout.write === "function") {
		const originalStdoutWrite = process.stdout.write.bind(process.stdout);
		process.stdout.write = function ccUiFilteredStdoutWrite(chunk: any, ...args: any[]): boolean {
			if (typeof chunk === "string" && (chunk.includes("\x1b[2J\x1b[3J\x1b[H") || chunk.includes("\x1b[3J\x1b[H"))) {
				return true;
			}
			return (originalStdoutWrite as any)(chunk, ...args);
		};
		pStdout[STDOUT_FLAG] = true;
	}
}
