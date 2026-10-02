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

export function visibleWidth(text: string): number {
	return text.replace(TERMINAL_CONTROL_RE, "").length;
}

export function clipPath(path: string, maxWidth: number): string {
	if (visibleWidth(path) <= maxWidth) return path;
	if (maxWidth <= 3) return "…";
	return "…" + path.slice(-(maxWidth - 1));
}

export interface CardRowInfo {
	isNeon: boolean;
	isFloat: boolean;
	usableWidth: number;
	leftPrefix: string;
	rightSuffix: string;
	body: string;
}

export function parseCardRow(template: string): CardRowInfo | undefined {
	const plain = template.replace(TERMINAL_CONTROL_RE, "");
	// Skip top/bottom corner rows
	if (/^[ ╭╰]/.test(plain) && (plain.includes("─") || plain.includes("╮") || plain.includes("╯"))) {
		return undefined;
	}

	const isNeon = plain.includes("│") && plain.lastIndexOf("│") > plain.indexOf("│");
	const isFloat = plain.includes("▎");
	if (!isNeon && !isFloat) return undefined;

	if (isNeon) {
		const left = template.indexOf("│");
		const right = template.lastIndexOf("│");
		const usableWidth = Math.max(0, visibleWidth(template.slice(left + 1, right)) - 2);
		const leftPrefix = template.slice(0, left + 1) + " ";
		const rightSuffix = " " + template.slice(right);
		const body = plain.slice(plain.indexOf("│") + 1, plain.lastIndexOf("│")).trim();
		return { isNeon: true, isFloat: false, usableWidth, leftPrefix, rightSuffix, body };
	}

	const left = template.indexOf("▎");
	const resetIdx = template.lastIndexOf("\x1b[49m");
	const leftPrefix = template.slice(0, left + 1) + " ";
	const rightSuffix = resetIdx >= 0 ? " " + template.slice(resetIdx) : " ";
	const usableWidth = Math.max(0, visibleWidth(plain) - visibleWidth(leftPrefix) - visibleWidth(rightSuffix));
	const body = plain.slice(plain.indexOf("▎") + 1).trim();
	return { isNeon: false, isFloat: true, usableWidth, leftPrefix, rightSuffix, body };
}

export function formatCardRow(template: string, leftText: string, rightText = ""): string {
	const parsed = parseCardRow(template);
	if (!parsed) return template;
	const leftWidth = visibleWidth(leftText);
	const rightWidth = visibleWidth(rightText);
	if (!rightText) {
		const pad = " ".repeat(Math.max(0, parsed.usableWidth - leftWidth));
		return `${parsed.leftPrefix}${leftText}${pad}${parsed.rightSuffix}`;
	}
	const gap = Math.max(1, parsed.usableWidth - leftWidth - rightWidth);
	const pad = " ".repeat(gap);
	return `${parsed.leftPrefix}${leftText}${pad}${rightText}${parsed.rightSuffix}`;
}

/**
 * Transforms Gentle sidebar cards so content spans the full available card width
 * using clean two-column key/value alignment, eliminating wasted space and left-heavy stacking.
 */
export function formatGentleSidebarCards(lines: string[]): string[] {
	const result: string[] = [];
	let index = 0;

	while (index < lines.length) {
		const line = lines[index]!;
		const parsed = parseCardRow(line);
		if (!parsed) {
			result.push(line);
			index++;
			continue;
		}

		const body = parsed.body;

		// 1. Project section
		if (body === "Project" && index + 1 < lines.length) {
			const nextParsed = parseCardRow(lines[index + 1]!);
			const rawPath = nextParsed?.body.replace(/^~?\/?/, (m) => m) ?? "";
			const maxPathWidth = Math.max(10, parsed.usableWidth - visibleWidth("Project") - 2);
			const path = clipPath(rawPath, maxPathWidth);

			result.push(formatCardRow(line, "\x1b[1mProject\x1b[22m", `\x1b[36m${path}\x1b[39m`));
			index += 2; // consumed "Project" and path

			// Check for Branch, Session, Profile
			while (index < lines.length) {
				const subParsed = parseCardRow(lines[index]!);
				if (!subParsed || subParsed.body === "") break;
				const branchMatch = subParsed.body.match(/^Branch\s+(.+)$/i);
				if (branchMatch) {
					result.push(formatCardRow(lines[index]!, "Branch", `\x1b[32m ${branchMatch[1]}\x1b[39m`));
					index++;
					continue;
				}
				const sessionMatch = subParsed.body.match(/^Session\s+(.+)$/i);
				if (sessionMatch) {
					result.push(formatCardRow(lines[index]!, "Session", `\x1b[35m${sessionMatch[1]}\x1b[39m`));
					index++;
					continue;
				}
				const profileMatch = subParsed.body.match(/^Profile\s+(.+)$/i);
				if (profileMatch) {
					result.push(formatCardRow(lines[index]!, "Profile", `\x1b[33m${profileMatch[1]}\x1b[39m`));
					index++;
					continue;
				}
				result.push(lines[index]!);
				index++;
			}
			continue;
		}

		// 2. Changes section
		if (body === "Changes" && index + 1 < lines.length) {
			const nextParsed = parseCardRow(lines[index + 1]!);
			const changesText = nextParsed?.body ?? "No captured changes";
			const isNone = /no captured changes/i.test(changesText);
			const formattedValue = isNone
				? `\x1b[90m${changesText}\x1b[39m`
				: `\x1b[33m${changesText}\x1b[39m`;

			result.push(formatCardRow(line, "\x1b[1mChanges\x1b[22m", formattedValue));
			index += 2; // skip "Changes" and its status line

			// Skip command line like "/gentle:changes"
			if (index < lines.length) {
				const cmdParsed = parseCardRow(lines[index]!);
				if (cmdParsed?.body.startsWith("/gentle:changes")) {
					index++;
				}
			}
			continue;
		}

		// 3. Integrations section
		if (body === "Integrations") {
			result.push(formatCardRow(line, "\x1b[1mIntegrations\x1b[22m"));
			index++;
			while (index < lines.length) {
				const itemParsed = parseCardRow(lines[index]!);
				if (!itemParsed || itemParsed.body === "") break;
				const isRuntimeStatus = /^(?:🧠||🔌|)\s/.test(itemParsed.body);
				if (!isRuntimeStatus) {
					index++;
					continue;
				}
				let itemBody = itemParsed.body;
				itemBody = itemBody.replace(/^🧠\s*/, " ").replace(/^🔌\s*/, " ");

				const dotIdx = itemBody.indexOf("·");
				const colonIdx = itemBody.indexOf(":");
				if (dotIdx >= 0) {
					const left = itemBody.slice(0, dotIdx).trim();
					const right = itemBody.slice(dotIdx + 1).trim();
					const rightStyled = right === "ready" ? `\x1b[32m● ready\x1b[39m` : right;
					result.push(formatCardRow(lines[index]!, `  ${left}`, rightStyled));
				} else if (colonIdx >= 0) {
					const left = itemBody.slice(0, colonIdx).trim();
					const right = itemBody.slice(colonIdx + 1).trim();
					result.push(formatCardRow(lines[index]!, `  ${left}`, `\x1b[36m${right}\x1b[39m`));
				} else {
					result.push(formatCardRow(lines[index]!, `  ${itemBody}`));
				}
				index++;
			}
			continue;
		}

		// 4. RDD section (if present)
		if (body.includes("RDD") && index + 1 < lines.length) {
			const nextParsed = parseCardRow(lines[index + 1]!);
			result.push(formatCardRow(line, "\x1b[1m🌹 RDD\x1b[22m", nextParsed ? `\x1b[35m${nextParsed.body}\x1b[39m` : ""));
			index += 2;
			continue;
		}

		result.push(line);
		index++;
	}

	return result;
}

