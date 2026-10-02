import assert from "node:assert/strict";
import test from "node:test";
import {
	GENTLE_SIDEBAR_STATE,
	LAYOUT_NODE,
	patchGentleSidebarParts,
	stripGentleHeaderLayoutNode,
	suppressGentleBelowInputWidget,
	suppressGentleHeader,
} from "./gentle-header.ts";

test("patchGentleSidebarParts prevents header rail from being stored or read", () => {
	const parts = new Map<string, unknown>();
	parts.set("header", { id: "old-header" });
	patchGentleSidebarParts(parts);

	assert.equal(parts.get("header"), undefined);
	assert.equal(parts.has("header"), false);

	// Attempting to set header is ignored
	parts.set("header", { id: "new-header", render: () => ["header-line"] });
	assert.equal(parts.get("header"), undefined);
	assert.equal(parts.has("header"), false);

	// Other parts are preserved and can still be set/read
	parts.set("footer", { id: "status-bar" });
	assert.deepEqual(parts.get("footer"), { id: "status-bar" });
	assert.equal(parts.has("footer"), true);
});

test("suppressGentleHeader initializes terminal sidebar state and guards future replacements", () => {
	const terminal: Record<symbol, unknown> = {};
	suppressGentleHeader(terminal);

	const state = terminal[GENTLE_SIDEBAR_STATE] as { parts: Map<string, unknown> };
	assert.ok(state);
	assert.ok(state.parts instanceof Map);

	// Setting header on state.parts is suppressed
	state.parts.set("header", { render: () => ["header"] });
	assert.equal(state.parts.get("header"), undefined);

	// If Gentle reassigns terminal[GENTLE_SIDEBAR_STATE], setter protects new parts
	const newParts = new Map<string, unknown>();
	terminal[GENTLE_SIDEBAR_STATE] = { active: true, parts: newParts };
	newParts.set("header", { render: () => ["header"] });
	assert.equal(newParts.get("header"), undefined);
});

test("stripGentleHeaderLayoutNode unwraps Gentle top vstack to reveal inner hstack/layout", () => {
	const innerHstack = {
		type: "hstack",
		gap: 0,
		align: "stretch",
		entries: [
			{ component: {}, basis: 0, grow: 1 },
			{ component: {}, basis: 50, grow: 0 },
		],
	};

	const hstackHost = {
		render: () => [],
		[LAYOUT_NODE]: () => innerHstack,
	};

	const vstackWithHeader = {
		type: "vstack",
		gap: 0,
		align: "stretch",
		entries: [
			{ component: { render: () => ["header"] }, basis: "auto", grow: 0, shrink: 0, minSize: 1 },
			{ component: hstackHost, basis: 0, grow: 1, shrink: 1, minSize: 1 },
		],
	};

	const unwrapped = stripGentleHeaderLayoutNode(vstackWithHeader);
	assert.deepEqual(unwrapped, innerHstack);

	// Non-header layout is returned untouched
	assert.deepEqual(stripGentleHeaderLayoutNode(innerHstack), innerHstack);
});

test("suppressGentleBelowInputWidget clears below-input widget", () => {
	const calls: Array<{ key: string; value: unknown }> = [];
	const widgetsBelow = new Map<string, unknown>([["gentle-shell-below-input-header", {}]]);
	const widgetsAbove = new Map<string, unknown>([["gentle-shell-below-input-header", {}]]);

	const host = {
		setExtensionWidget: (key: string, value: unknown) => calls.push({ key, value }),
		extensionWidgetsBelow: widgetsBelow,
		extensionWidgetsAbove: widgetsAbove,
	};

	suppressGentleBelowInputWidget(host);

	assert.equal(widgetsBelow.has("gentle-shell-below-input-header"), false);
	assert.equal(widgetsAbove.has("gentle-shell-below-input-header"), false);
	assert.ok(calls.some((c) => c.key === "gentle-shell-below-input-header" && c.value === undefined));
});
