import assert from "node:assert/strict";
import test from "node:test";
import {
	GENTLE_SIDEBAR_STATE,
	LAYOUT_NODE,
	patchGentleSidebarParts,
	stripGentleHeaderLayoutNode,
	suppressGentleBelowInputWidget,
	suppressGentleHeader,
	withoutGentleSidebarBanner,
	isGentleSidebarBannerLine,
	formatGentleSidebarCards,
	parseCardRow,
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

test("isGentleSidebarBannerLine detects Gentle Shell and Gentle-Pi banner rows", () => {
	assert.equal(isGentleSidebarBannerLine("   ✿ Gentle Shell ✿   "), true);
	assert.equal(isGentleSidebarBannerLine(" \x1b[35m✿\x1b[39m \x1b[37mGentle Shell\x1b[39m \x1b[35m✿\x1b[39m "), true);
	assert.equal(isGentleSidebarBannerLine("   ✿ Gentle-Pi ✿   "), true);
	assert.equal(isGentleSidebarBannerLine("   Gentle-Pi   "), true);

	// Card headers and other content are not banner lines
	assert.equal(isGentleSidebarBannerLine(" ╭─ ✿ Status ────────────────────────────────────╮ "), false);
	assert.equal(isGentleSidebarBannerLine(" │ Project: ~/foo                                │ "), false);
	assert.equal(isGentleSidebarBannerLine(""), false);
	assert.equal(isGentleSidebarBannerLine("   "), false);
});

test("withoutGentleSidebarBanner removes the ornamental banner and leading spacer", () => {
	const rawRailLines = [
		"   \x1b[35m✿\x1b[39m \x1b[37mGentle Shell\x1b[39m \x1b[35m✿\x1b[39m   ",
		"",
		" ╭─ ✿ Status ────────────────────────────────────╮ ",
		" │ Project                                       │ ",
		" │ ~/Proyectos/pi-custom                         │ ",
		" ╰───────────────────────────────────────────────╯ ",
	];

	const cleaned = withoutGentleSidebarBanner(rawRailLines);
	assert.deepEqual(cleaned, [
		" ╭─ ✿ Status ────────────────────────────────────╮ ",
		" │ Project                                       │ ",
		" │ ~/Proyectos/pi-custom                         │ ",
		" ╰───────────────────────────────────────────────╯ ",
	]);
});

test("withoutGentleSidebarBanner preserves all subsequent rail cards and sections", () => {
	const multiCardRailLines = [
		"   \x1b[35m✿\x1b[39m \x1b[37mGentle Shell\x1b[39m \x1b[35m✿\x1b[39m   ",
		"",
		" ╭─ ✿ Status ────────────────────────────────────╮ ",
		" │ Project                                       │ ",
		" │ ~/Proyectos/pi-custom                         │ ",
		" ╰───────────────────────────────────────────────╯ ",
		"",
		" ╭─ ✿ Changes ───────────────────────────────────╮ ",
		" │ 1 file changed (+10 -2)                       │ ",
		" ╰───────────────────────────────────────────────╯ ",
		"",
		" ╭─ ✿ Integrations ──────────────────────────────╮ ",
		" │ git: clean                                    │ ",
		" ╰───────────────────────────────────────────────╯ ",
	];

	const cleaned = withoutGentleSidebarBanner(multiCardRailLines);
	assert.deepEqual(cleaned, [
		" ╭─ ✿ Status ────────────────────────────────────╮ ",
		" │ Project                                       │ ",
		" │ ~/Proyectos/pi-custom                         │ ",
		" ╰───────────────────────────────────────────────╯ ",
		"",
		" ╭─ ✿ Changes ───────────────────────────────────╮ ",
		" │ 1 file changed (+10 -2)                       │ ",
		" ╰───────────────────────────────────────────────╯ ",
		"",
		" ╭─ ✿ Integrations ──────────────────────────────╮ ",
		" │ git: clean                                    │ ",
		" ╰───────────────────────────────────────────────╯ ",
	]);
});

test("formatGentleSidebarCards formats float cards into balanced two-column key-value rows", () => {
	const TERMINAL_CONTROL_RE = /\x1b\[[0-9:;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][AB0]/g;
	const strip = (s: string) => s.replace(TERMINAL_CONTROL_RE, "");

	const bg = "\x1b[48;2;20;25;30m";
	const bgReset = "\x1b[49m";
	const frameColor = "\x1b[38;2;200;200;200m";
	const reset = "\x1b[39m";
	const width = 48;

	const makeRow = (text: string) => {
		const innerWidth = width - 4;
		const pad = " ".repeat(Math.max(0, innerWidth - strip(text).length));
		return ` ${bg}${frameColor}▎${reset} ${text}${pad} ${bgReset} `;
	};

	const rawFloatLines = [
		makeRow(""),
		makeRow("✿ Status"),
		makeRow(""),
		makeRow("Project"),
		makeRow("  ~/Proyectos/pi-custom"),
		makeRow("  Branch master"),
		makeRow(""),
		makeRow("Changes"),
		makeRow("  No captured changes"),
		makeRow("  /gentle:changes"),
		makeRow(""),
		makeRow("Integrations"),
		makeRow("  🧠 pi-custom · ready"),
		makeRow("  🔌 MCP: 2 servers enabled"),
		makeRow(""),
	];

	const formatted = formatGentleSidebarCards(rawFloatLines);

	// All generated rows maintain exact card width
	for (const line of formatted) {
		assert.equal(strip(line).length, width + 1);
	}

	const plainLines = formatted.map(strip);
	// Project is inlined into a single key-value row
	const projectLine = plainLines.find((l) => l.includes("Project"));
	assert.ok(projectLine);
	assert.ok(projectLine.includes("Project") && projectLine.includes("~/Proyectos/pi-custom"));

	// Branch is inlined with git glyph
	const branchLine = plainLines.find((l) => l.includes("Branch"));
	assert.ok(branchLine);
	assert.ok(branchLine.includes("Branch") && branchLine.includes("master"));

	// Changes is inlined
	const changesLine = plainLines.find((l) => l.includes("Changes"));
	assert.ok(changesLine);
	assert.ok(changesLine.includes("Changes") && changesLine.includes("No captured changes"));

	// Integrations are formatted with Nerd Font icons and right-aligned statuses
	const piLine = plainLines.find((l) => l.includes("ready"));
	assert.ok(piLine);
	assert.ok(piLine.includes(" pi-custom") && piLine.includes("ready"));

	const mcpLine = plainLines.find((l) => l.includes("MCP"));
	assert.ok(mcpLine);
	assert.ok(mcpLine.includes(" MCP") && mcpLine.includes("2 servers enabled"));
});

test("formatGentleSidebarCards formats neon cards into balanced two-column rows", () => {
	const TERMINAL_CONTROL_RE = /\x1b\[[0-9:;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][AB0]/g;
	const strip = (s: string) => s.replace(TERMINAL_CONTROL_RE, "");

	const frameColor = "\x1b[38;2;200;200;200m";
	const reset = "\x1b[39m";
	const width = 48;

	const makeRow = (text: string) => {
		const innerWidth = width - 4;
		const pad = " ".repeat(Math.max(0, innerWidth - strip(text).length));
		return ` ${frameColor}│${reset} ${text}${pad} ${frameColor}│${reset} `;
	};

	const rawNeonLines = [
		" ╭─ ✿ Status ────────────────────────────────────╮ ",
		makeRow("Project"),
		makeRow("  ~/Proyectos/pi-custom"),
		makeRow("  Branch master"),
		makeRow(""),
		makeRow("Changes"),
		makeRow("  No captured changes"),
		makeRow("  /gentle:changes"),
		makeRow(""),
		makeRow("Integrations"),
		makeRow("  🧠 pi-custom · ready"),
		makeRow("  🔌 MCP: 2 servers enabled"),
		" ╰───────────────────────────────────────────────╯ ",
	];

	const formatted = formatGentleSidebarCards(rawNeonLines);

	const plainLines = formatted.map(strip);
	const projectLine = plainLines.find((l) => l.includes("Project"));
	assert.ok(projectLine);
	assert.ok(projectLine.includes("Project") && projectLine.includes("~/Proyectos/pi-custom"));

	const branchLine = plainLines.find((l) => l.includes("Branch"));
	assert.ok(branchLine);
	assert.ok(branchLine.includes("Branch") && branchLine.includes("master"));
});


