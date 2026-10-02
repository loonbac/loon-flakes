/**
 * Header panel suppression for gentle-pi integration.
 *
 * Gentle Shell paints a top header row with brand, session identity, and usage
 * counters above the fullscreen layout. When a custom bottom status line is
 * already active, that top row is redundant and consumes vertical space.
 *
 * This module:
 *  1. Intercepts Gentle's terminal-owned sidebar `parts` Map so that the "header"
 *     rail is never registered or read by Gentle's sidebar layout.
 *  2. Unwraps any legacy/memoized top vstack layout node so the transcript or
 *     rail hstack gets full vertical space immediately.
 *  3. Suppresses Gentle's below-input header widget slot ("gentle-shell-below-input-header").
 */

export const GENTLE_SIDEBAR_STATE = Symbol.for("gentle-pi.experimental-sidebar.state");
export const GENTLE_HEADER_SUPPRESSED = Symbol.for("better-cc-ui:gentle-header-suppressed");
export const LAYOUT_NODE = Symbol.for("@earendil-works/pi-tui/layout-node");

export type GentleSidebarState = {
	active?: boolean;
	ownsHost?: () => boolean;
	parts?: Map<string, unknown>;
	headerOwnsStatus?: () => boolean;
};

export type LayoutNodeLike = {
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

export function patchGentleSidebarParts(parts: Map<string, unknown>): void {
	if ((parts as unknown as Record<symbol, unknown>)[GENTLE_HEADER_SUPPRESSED]) return;
	(parts as unknown as Record<symbol, unknown>)[GENTLE_HEADER_SUPPRESSED] = true;

	parts.delete("header");

	const originalSet = parts.set.bind(parts);
	parts.set = function ccUiNoGentleHeaderSet(key: string, value: unknown) {
		if (key === "header") {
			// Do not store the header in parts so that Gentle's sidebar layout
			// never synthesizes the top header row, leaving all top rows for
			// the transcript.
			return parts;
		}
		return originalSet(key, value);
	};

	const originalGet = parts.get.bind(parts);
	parts.get = function ccUiNoGentleHeaderGet(key: string) {
		if (key === "header") return undefined;
		return originalGet(key);
	};

	const originalHas = parts.has.bind(parts);
	parts.has = function ccUiNoGentleHeaderHas(key: string) {
		if (key === "header") return false;
		return originalHas(key);
	};
}

export function suppressGentleHeader(uiOrTerminal: unknown): void {
	const terminal = (uiOrTerminal as { terminal?: Record<symbol, unknown> } | undefined)?.terminal
		?? (uiOrTerminal as Record<symbol, unknown> | undefined);
	if (!terminal) return;

	let state = terminal[GENTLE_SIDEBAR_STATE] as GentleSidebarState | undefined;
	if (state?.parts) {
		patchGentleSidebarParts(state.parts);
	} else if (!state) {
		const parts = new Map<string, unknown>();
		patchGentleSidebarParts(parts);
		state = { active: false, parts };
		terminal[GENTLE_SIDEBAR_STATE] = state;
	}

	const stateDesc = Object.getOwnPropertyDescriptor(terminal, GENTLE_SIDEBAR_STATE);
	if (!stateDesc || stateDesc.configurable) {
		let currentState = state;
		try {
			Object.defineProperty(terminal, GENTLE_SIDEBAR_STATE, {
				configurable: true,
				enumerable: true,
				get() {
					return currentState;
				},
				set(nextState: GentleSidebarState | undefined) {
					currentState = nextState;
					if (nextState?.parts) {
						patchGentleSidebarParts(nextState.parts);
					}
				},
			});
		} catch {
			// Ignore if property is non-configurable
		}
	}
}

export function suppressGentleBelowInputWidget(host: unknown): void {
	const mode = host as {
		setExtensionWidget?: (key: string, content: unknown) => void;
		extensionWidgetsBelow?: Map<string, unknown>;
		extensionWidgetsAbove?: Map<string, unknown>;
		ui?: { setWidget?: (key: string, content: unknown) => void };
	} | undefined;
	if (!mode) return;
	try {
		mode.setExtensionWidget?.("gentle-shell-below-input-header", undefined);
		mode.ui?.setWidget?.("gentle-shell-below-input-header", undefined);
		mode.extensionWidgetsBelow?.delete("gentle-shell-below-input-header");
		mode.extensionWidgetsAbove?.delete("gentle-shell-below-input-header");
	} catch {
		// Ignore if widgets are not present
	}
}

export function stripGentleHeaderLayoutNode(node: LayoutNodeLike): LayoutNodeLike {
	if (node?.type !== "vstack" || !Array.isArray(node.entries) || node.entries.length !== 2) {
		return node;
	}
	const [top, bottom] = node.entries;
	if (top?.basis === "auto" && top.grow === 0 && bottom?.component) {
		const bottomComponent = bottom.component as Record<symbol, unknown>;
		const nestedLayout = bottomComponent[LAYOUT_NODE];
		if (typeof nestedLayout === "function") {
			try {
				const inner = (nestedLayout as () => LayoutNodeLike).call(bottomComponent);
				if (inner && typeof inner === "object" && typeof inner.type === "string") {
					return inner;
				}
			} catch {
				// Keep raw node if unwrap fails.
			}
		}
	}
	return node;
}

export const TERMINAL_CONTROL_RE = /\x1b\[[0-9:;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][AB0]/g;

export function isGentleSidebarBannerLine(line: string): boolean {
	const plain = line.replace(TERMINAL_CONTROL_RE, "").trim();
	if (!plain) return false;
	return plain.includes("Gentle Shell")
		|| plain.includes("Gentle-Pi")
		|| (plain.includes("Gentle") && plain.includes("✿"))
		|| (plain.startsWith("✿") && plain.endsWith("✿"));
}

/** Remove Gentle's ornamental rail banner and its following section spacer. */
export function withoutGentleSidebarBanner(lines: string[]): string[] {
	const filtered: string[] = [];
	let skipSpacer = false;
	for (const line of lines) {
		if (isGentleSidebarBannerLine(line)) {
			skipSpacer = true;
			continue;
		}
		if (skipSpacer && line.replace(TERMINAL_CONTROL_RE, "").trim() === "") {
			skipSpacer = false;
			continue;
		}
		skipSpacer = false;
		filtered.push(line);
	}
	while (filtered.length > 0 && filtered[0]!.replace(TERMINAL_CONTROL_RE, "").trim() === "") {
		filtered.shift();
	}
	return filtered;
}
