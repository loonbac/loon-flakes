/**
 * better-claude-code-ui — Claude Code visual identity for pi.
 *
 * Layers:
 *   1. themes/            six CC color themes (JSON, loaded by pi)
 *   2. chrome             banner (welcome box), spinner, status line, turn footer
 *   3. tools/             CC-style tool rendering (builtins, diff, grouping)
 *   4. thinking           CC-style thinking title + hidden label + spinner row
 *
 * Layers 1-4 use only pi public extension APIs. host-patches.ts additionally
 * wraps two prototype methods of PUBLIC pi exports (AssistantMessageComponent,
 * InteractiveMode) as the extension-side landing of the upstream PR draft —
 * see its header for scope and removal criteria.
 * See ALIGNMENT.md for the per-module CC source mapping.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { installHostPatches } from "./host-patches.js";
import { registerSpinner } from "./spinner.js";
import { registerTurnFooter } from "./turn-footer.js";
import { registerBanner } from "./banner.js";
import { registerStatusLine } from "./status-line.js";
import { registerGrouping } from "./tools/grouping.js";
import { registerBuiltins } from "./tools/builtins.js";
import { registerCommands } from "./commands.js";
import { registerThinking } from "./thinking.js";
import { registerPromptPointer } from "./prompt-editor.js";
import { FastModeIndicator, type FastModeIndicatorUi } from "./fast-mode-indicator.js";
import { WallpaperAccentSync, type WallpaperThemeUi } from "./wallpaper-sync.js";
import { registerAntigravityUsage } from "./antigravity-usage.js";
import { registerCommandCodeUsage } from "./commandcode-usage.js";
import { registerOpenCodeGoUsage } from "./opencode-go-usage.js";
import { registerCodexUsageCache } from "./codex-usage-cache.js";
import { ensureFallbackConfig } from "./fallback-config.js";
import { registerBoundedSearch } from "./bounded-search.js";

/**
 * gentle-pi's quiet-tools extension owns the same seven built-in tool names.
 * Let it keep those registrations when it is active, while the rest of this
 * extension (including wallpaper colors) continues to load. Set
 * GENTLE_PI_QUIET_TOOLS=0 to give these CC renderers ownership instead.
 */
function gentlePiQuietToolsAreActive(): boolean {
	if (process.env.GENTLE_PI_QUIET_TOOLS === "0") return false;
	try {
		const settingsPaths = [
			join(homedir(), ".pi", "agent", "settings.json"),
			join(homedir(), ".pi", "settings.json"),
			join(process.cwd(), ".pi", "settings.json"),
		];
		for (const p of settingsPaths) {
			if (!existsSync(p)) continue;
			const settings = JSON.parse(readFileSync(p, "utf8")) as { packages?: unknown; extensions?: unknown };
			if (Array.isArray(settings.packages) && settings.packages.some(
				(source) => typeof source === "string" && (source.includes("gentle-pi") || /^(?:npm:)?gentle-pi(?:@|$)/u.test(source)),
			)) return true;
			if (Array.isArray(settings.extensions) && settings.extensions.some(
				(source) => typeof source === "string" && source.includes("gentle-pi"),
			)) return true;
		}
	} catch {
		// ignore
	}
	return existsSync(join(homedir(), "Proyectos", "gentle-pi", "extensions", "quiet-tools.ts")) ||
		existsSync(join(homedir(), ".pi", "agent", "npm", "node_modules", "gentle-pi", "extensions", "quiet-tools.ts"));
}

function shouldRegisterStandaloneStatusLine(): boolean {
	if (process.env.BETTER_CC_STATUS_LINE === "0") return false;
	try {
		const settingsPath = join(homedir(), ".pi", "agent", "settings.json");
		const settings = JSON.parse(readFileSync(settingsPath, "utf8")) as { packages?: unknown };
		if (!Array.isArray(settings.packages)) return true;
		// Both packages own ctx.ui.setFooter(). Registering ours after Gentle's
		// session_start handler disposes its footer, whose dispose callback also
		// uninstalls the complete fullscreen sidebar. Keep decorating Gentle's
		// footer through host-patches.ts, but never replace it here.
		return !settings.packages.some((source) => typeof source === "string" && (
			/pi-statusline/u.test(source)
			|| source.includes("gentle-pi")
			|| /^(?:npm:)?gentle-pi(?:@|$)/u.test(source)
		));
	} catch {
		return true;
	}
}

export default function (pi: ExtensionAPI) {
	// NixOS whole-filesystem searches fan out through /nix/store. Teach every
	// parent/child session the bounded alternative and enforce it at tool time.
	registerBoundedSearch(pi);
	// Keep the custom fallback editor/runtime and gentle-pi 2.7's named profile
	// store reconciled even when the user has not opened /gentle:models yet.
	ensureFallbackConfig();
	// Host patches (ghost blank rows, ctrl+o status residue) — before any render.
	installHostPatches();
	registerAntigravityUsage(pi);
	registerCommandCodeUsage(pi);
	registerOpenCodeGoUsage(pi);
	registerCodexUsageCache(pi);

	// Layer 2: chrome
	registerSpinner(pi);
	registerTurnFooter(pi);
	registerBanner(pi);
	if (shouldRegisterStandaloneStatusLine()) registerStatusLine(pi);
	registerPromptPointer(pi);

	// Layer 3: tool rendering
	registerGrouping(pi);
	if (!gentlePiQuietToolsAreActive()) registerBuiltins(pi);

	// Layer 4: thinking (transformer + hidden label + spinner-row coordination)
	registerThinking(pi);

	// Commands + shortcuts
	registerCommands(pi);

	// Keep the CC brand roles aligned with the wallpaper producer's live accent.
	const wallpaperSync = new WallpaperAccentSync();
	const fastModeIndicator = new FastModeIndicator();
	pi.on("session_start", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		fastModeIndicator.start(ctx.ui as unknown as FastModeIndicatorUi);
		await wallpaperSync.start(ctx.ui as unknown as WallpaperThemeUi);
	});
	pi.on("session_shutdown", async () => {
		fastModeIndicator.stop();
		wallpaperSync.stop();
	});
}
