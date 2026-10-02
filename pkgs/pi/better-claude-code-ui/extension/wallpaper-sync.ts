/**
 * Live wallpaper accent synchronization.
 *
 * mpvpaper/accent-wallpaper maintains ~/.config/mpvpaper/accent.txt. This
 * module reads that producer-owned file only; it neither runs an analyser nor
 * writes wallpaper/theme files.
 */
import { readFileSync, watch } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { setWallpaperAccent } from "./palette.ts";

const DEFAULT_DEBOUNCE_MS = 80;
const DEFAULT_THEME_POLL_MS = 250;
const WALLPAPER_REDRAW = Symbol.for("better-cc-ui:wallpaper-redraw");
const TRANSCRIPT_THEME = Symbol.for("better-cc-ui:transcript-theme");
// Pi composes a card border from all three roles. Update them as a unit so a
// wallpaper change cannot leave an accent-colored title segment on an
// otherwise neutral (and visually broken) frame.
// Gentle INFO cards paint their title and left rail with customMessageLabel.
// It must be the *same* accent as the frame roles; using the lighter shimmer
// here made Status and Changes look like two different wallpaper colors.
const BRAND_ROLES = ["claude", "border", "borderAccent", "borderMuted", "toolTitle", "customMessageLabel", "scrollbarThumb"] as const;
const SHIMMER_ROLES = ["claudeShimmer"] as const;

type ColorMode = "truecolor" | "256color";

/** The public runtime shape used by Theme; a clone retains the original prototype. */
export interface RuntimeTheme {
	name?: string;
	sourcePath?: string;
	sourceInfo?: unknown;
	fgAnsi?: Map<string, string>;
	bgAnsi?: Map<string, string>;
	fgColors?: Map<string, string>;
	bgColors?: Map<string, string>;
	getColorMode?: () => ColorMode | string;
}

export function getFgMap(theme: unknown): Map<string, string> | undefined {
	if (!theme || typeof theme !== "object") return undefined;
	const t = theme as Record<string, unknown>;
	if (t.fgAnsi instanceof Map) return t.fgAnsi as Map<string, string>;
	if (t.fgColors instanceof Map) return t.fgColors as Map<string, string>;
	return undefined;
}

export function getBgMap(theme: unknown): Map<string, string> | undefined {
	if (!theme || typeof theme !== "object") return undefined;
	const t = theme as Record<string, unknown>;
	if (t.bgAnsi instanceof Map) return t.bgAnsi as Map<string, string>;
	if (t.bgColors instanceof Map) return t.bgColors as Map<string, string>;
	return undefined;
}

export interface WallpaperThemeUi {
	theme?: RuntimeTheme;
	getTheme?: (name: string) => RuntimeTheme | undefined;
	setTheme(theme: RuntimeTheme): unknown;
	/** Present on Pi's interactive UI; optional for the narrow test doubles. */
	invalidate?(): void;
	requestRender?(): void;
	/** Installed by Gentle Shell on its sidebar host. */
	invalidateSidebar?(): void;
}

type WatchListener = (eventType: string, filename: string | Buffer | null) => void;

interface ClosableWatcher {
	close(): void;
	unref?(): void;
	on?(event: "error", listener: () => void): unknown;
}

export interface WallpaperAccentSyncOptions {
	/** Test hook. Production always resolves the default from homedir(). */
	accentPath?: string;
	debounceMs?: number;
	themePollMs?: number;
	readAccentText?: (path: string) => Promise<string>;
	watchDirectory?: (path: string, listener: WatchListener) => ClosableWatcher;
}

function defaultAccentPath(): string {
	return join(homedir(), ".config", "mpvpaper", "accent.txt");
}

function unref(timer: ReturnType<typeof setTimeout> | ReturnType<typeof setInterval>): void {
	(timer as unknown as { unref?: () => void }).unref?.();
}

/** Parse exactly one complete accent value; partial writes are intentionally ignored. */
export function parseAccentHex(content: string): string | undefined {
	const hex = content.trim();
	return /^#[0-9a-fA-F]{6}$/u.test(hex) ? hex.toUpperCase() : undefined;
}

/** Blend toward white to produce the lighter Claude shimmer role. */
export function deriveShimmer(accent: string): string {
	const hex = parseAccentHex(accent);
	if (hex === undefined) throw new Error("deriveShimmer requires a #RRGGBB accent");
	const channel = (offset: number) => {
		const value = Number.parseInt(hex.slice(offset, offset + 2), 16);
		return Math.round(value + (255 - value) * 0.35).toString(16).padStart(2, "0").toUpperCase();
	};
	return `#${channel(1)}${channel(3)}${channel(5)}`;
}

function rgbChannels(hex: string): [number, number, number] {
	return [
		Number.parseInt(hex.slice(1, 3), 16),
		Number.parseInt(hex.slice(3, 5), 16),
		Number.parseInt(hex.slice(5, 7), 16),
	];
}

const CUBE_VALUES = [0, 95, 135, 175, 215, 255] as const;
const GRAY_VALUES = Array.from({ length: 24 }, (_, index) => 8 + index * 10);

function nearestCube(value: number): number {
	let closest = 0;
	let distance = Infinity;
	for (let index = 0; index < CUBE_VALUES.length; index += 1) {
		const candidate = CUBE_VALUES[index] as number;
		const nextDistance = Math.abs(value - candidate);
		if (nextDistance < distance) {
			closest = index;
			distance = nextDistance;
		}
	}
	return closest;
}

function nearestGray(value: number): number {
	let closest = 0;
	let distance = Infinity;
	for (let index = 0; index < GRAY_VALUES.length; index += 1) {
		const candidate = GRAY_VALUES[index] as number;
		const nextDistance = Math.abs(value - candidate);
		if (nextDistance < distance) {
			closest = index;
			distance = nextDistance;
		}
	}
	return closest;
}

function colorDistance(r1: number, g1: number, b1: number, r2: number, g2: number, b2: number): number {
	const dr = r1 - r2;
	const dg = g1 - g2;
	const db = b1 - b2;
	return dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114;
}

function xterm256(hex: string): number {
	const [r, g, b] = rgbChannels(hex);
	const rIndex = nearestCube(r);
	const gIndex = nearestCube(g);
	const bIndex = nearestCube(b);
	const cubeR = CUBE_VALUES[rIndex] as number;
	const cubeG = CUBE_VALUES[gIndex] as number;
	const cubeB = CUBE_VALUES[bIndex] as number;
	const cubeIndex = 16 + 36 * rIndex + 6 * gIndex + bIndex;
	const cubeDistance = colorDistance(r, g, b, cubeR, cubeG, cubeB);
	const gray = Math.round(0.299 * r + 0.587 * g + 0.114 * b);
	const grayIndex = nearestGray(gray);
	const grayValue = GRAY_VALUES[grayIndex] as number;
	const grayDistance = colorDistance(r, g, b, grayValue, grayValue, grayValue);
	return Math.max(r, g, b) - Math.min(r, g, b) < 10 && grayDistance < cubeDistance ? 232 + grayIndex : cubeIndex;
}

function fgAnsi(hex: string, colorMode: ColorMode | string | undefined): string {
	if (colorMode === "256color") return `\x1b[38;5;${xterm256(hex)}m`;
	const [r, g, b] = rgbChannels(hex);
	return `\x1b[38;2;${r};${g};${b}m`;
}

function isRuntimeTheme(theme: RuntimeTheme | undefined): theme is RuntimeTheme {
	if (theme === undefined) return false;
	const fg = getFgMap(theme);
	const bg = getBgMap(theme);
	return fg instanceof Map && bg instanceof Map;
}

/** Ask the host patch to invalidate Gentle's sidebar cache, if it is mounted. */
function redrawWallpaperCards(): void {
	const redraw = (globalThis as unknown as Record<symbol, unknown>)[WALLPAPER_REDRAW];
	if (typeof redraw === "function") redraw();
}

/**
 * Clone a real pi Theme without mutating it. The clone shares its prototype,
 * so setTheme receives a genuine runtime Theme instance while every non-brand
 * color map entry remains identical to the selected CC theme.
 */
export function buildWallpaperTheme<T extends RuntimeTheme>(theme: T, accent: string): T {
	const normalized = parseAccentHex(accent);
	if (normalized === undefined) throw new Error("buildWallpaperTheme requires a #RRGGBB accent");
	const shimmer = deriveShimmer(normalized);
	const source = theme as T & { mode?: ColorMode | string };
	const sourcePrototype = Object.getPrototypeOf(theme);
	const clone = Object.create(
		sourcePrototype !== Object.prototype && sourcePrototype !== null ? sourcePrototype : Object.prototype,
	) as T & { mode?: ColorMode | string };
	Object.assign(clone, source);
	clone.name = source.name;
	clone.sourcePath = source.sourcePath;
	clone.sourceInfo = source.sourceInfo;
	const mode = theme.getColorMode?.();
	clone.mode = mode;

	const sourceFg = getFgMap(theme) ?? new Map();
	const fgMap = new Map(sourceFg);
	for (const role of BRAND_ROLES) fgMap.set(role, fgAnsi(normalized, mode));
	for (const role of SHIMMER_ROLES) fgMap.set(role, fgAnsi(shimmer, mode));
	clone.fgColors = fgMap;
	clone.fgAnsi = fgMap;

	const sourceBg = getBgMap(theme) ?? new Map();
	const bgMap = new Map(sourceBg);
	clone.bgColors = bgMap;
	clone.bgAnsi = bgMap;
	return clone as T;
}

/**
 * Gentle Shell closes over the Theme object supplied when it installs its
 * sidebar. Mutating that public Theme in place lets its cached renderers see a
 * wallpaper accent change; swapping in a cloned Theme leaves them pointing at
 * the old border colors.
 */
function applyWallpaperAccent(theme: RuntimeTheme, accent: string): void {
	const normalized = parseAccentHex(accent);
	if (normalized === undefined) throw new Error("applyWallpaperAccent requires a #RRGGBB accent");
	const mode = theme.getColorMode?.();
	const shimmer = deriveShimmer(normalized);
	const fgMap = getFgMap(theme);
	if (fgMap) {
		for (const role of BRAND_ROLES) fgMap.set(role, fgAnsi(normalized, mode));
		for (const role of SHIMMER_ROLES) fgMap.set(role, fgAnsi(shimmer, mode));
	}
	if (theme.fgColors instanceof Map && theme.fgColors !== fgMap) {
		for (const role of BRAND_ROLES) theme.fgColors.set(role, fgAnsi(normalized, mode));
		for (const role of SHIMMER_ROLES) theme.fgColors.set(role, fgAnsi(shimmer, mode));
	}
}

/** Watches the producer file for one session and maintains the in-memory Theme override. */
export class WallpaperAccentSync {
	private readonly accentPath: string;
	private readonly debounceMs: number;
	private readonly themePollMs: number;
	private readonly readAccentText: (path: string) => Promise<string>;
	private readonly watchDirectory: (path: string, listener: WatchListener) => ClosableWatcher;
	private ui: WallpaperThemeUi | undefined;
	private watcher: ClosableWatcher | undefined;
	private debounceTimer: ReturnType<typeof setTimeout> | undefined;
	private watchRetryTimer: ReturnType<typeof setTimeout> | undefined;
	private themePollTimer: ReturnType<typeof setInterval> | undefined;
	private activeAccent: string | undefined;
	private running = false;

	constructor(options: WallpaperAccentSyncOptions = {}) {
		this.accentPath = options.accentPath ?? defaultAccentPath();
		this.debounceMs = options.debounceMs ?? DEFAULT_DEBOUNCE_MS;
		this.themePollMs = options.themePollMs ?? DEFAULT_THEME_POLL_MS;
		this.readAccentText = options.readAccentText ?? ((path) => readFile(path, "utf8"));
		this.watchDirectory = options.watchDirectory ?? ((path, listener) => watch(path, listener));
	}

	async start(ui: WallpaperThemeUi): Promise<void> {
		this.stop();
		this.running = true;
		this.ui = ui;
		// Share the stable Theme proxy with transcript rendering. This also
		// covers the first /reload from an older patch, where Pi can construct
		// the extension context before the freshly loaded host patch runs.
		if (ui.theme !== undefined) {
			(globalThis as unknown as Record<symbol, unknown>)[TRANSCRIPT_THEME] = ui.theme;
		}
		// session_start listeners are registered by package order. Read the
		// producer synchronously so Gentle's later listener constructs its
		// sidebar with the wallpaper colors already in the shared Theme. An
		// asynchronous first read was the startup race behind the seemingly
		// random purple/blue cards.
		this.primeThemeForSessionStart();
		this.openWatcher();
		this.themePollTimer = setInterval(() => this.syncActiveTheme(), this.themePollMs);
		unref(this.themePollTimer);
		await this.refresh();
	}

	stop(): void {
		this.running = false;
		if (this.debounceTimer !== undefined) clearTimeout(this.debounceTimer);
		if (this.watchRetryTimer !== undefined) clearTimeout(this.watchRetryTimer);
		if (this.themePollTimer !== undefined) clearInterval(this.themePollTimer);
		this.debounceTimer = undefined;
		this.watchRetryTimer = undefined;
		this.themePollTimer = undefined;
		this.watcher?.close();
		this.watcher = undefined;
		this.ui = undefined;
		this.activeAccent = undefined;
		setWallpaperAccent(undefined);
	}

	/** Read and apply the file now. Missing/invalid content leaves the last good accent intact. */
	async refresh(): Promise<void> {
		if (!this.running) return;
		let content: string;
		try {
			content = await this.readAccentText(this.accentPath);
		} catch {
			return;
		}
		const accent = parseAccentHex(content);
		if (accent === undefined) return;
		if (accent !== this.activeAccent) {
			this.activeAccent = accent;
			setWallpaperAccent(accent, deriveShimmer(accent));
		}
		this.syncActiveTheme();
	}

	/**
	 * Overlay Pi's shared Theme from our extension, rather than editing any
	 * third-party package. Gentleman consumes the public Theme API, so this
	 * makes its complete frame follow the wallpaper and survives its updates.
	 */
	syncActiveTheme(): void {
		if (!this.running || this.activeAccent === undefined || this.ui === undefined) return;
		const theme = this.ui.theme;
		if (!isRuntimeTheme(theme)) {
			setWallpaperAccent(undefined);
			return;
		}
		try {
			setWallpaperAccent(this.activeAccent, deriveShimmer(this.activeAccent));
			const mode = theme.getColorMode?.();
			const expectedAccent = fgAnsi(this.activeAccent, mode);
			const expectedShimmer = fgAnsi(deriveShimmer(this.activeAccent), mode);
			// Do not repeatedly redraw every 250 ms.  The roles are written onto
			// the same Theme instance Gentleman captured when it built its cards.
			const fgMap = getFgMap(theme);
			if (
				fgMap?.get("claude") === expectedAccent &&
				fgMap?.get("border") === expectedAccent &&
				fgMap?.get("borderAccent") === expectedAccent &&
				fgMap?.get("borderMuted") === expectedAccent &&
				fgMap?.get("toolTitle") === expectedAccent &&
				fgMap?.get("customMessageLabel") === expectedAccent &&
				fgMap?.get("scrollbarThumb") === expectedAccent &&
				fgMap?.get("claudeShimmer") === expectedShimmer
			) return;
			applyWallpaperAccent(theme, this.activeAccent);
			// ctx.ui.theme is Pi's Theme *proxy*, not an instance accepted by
			// setTheme(). Passing it there makes Pi fall back to its default theme
			// on /reload. Keep the proxy's current Theme and redraw it in place.
			redrawWallpaperCards();
			this.ui.invalidateSidebar?.();
			this.ui.invalidate?.();
			this.ui.requestRender?.();
		} catch {
			// A cosmetic patch must never interrupt an active Pi session.
		}
	}

	/** Apply before later session_start listeners build components from Theme. */
	private primeThemeForSessionStart(): void {
		try {
			const accent = parseAccentHex(readFileSync(this.accentPath, "utf8"));
			const theme = this.ui?.theme;
			if (accent === undefined || !isRuntimeTheme(theme)) return;
			this.activeAccent = accent;
			setWallpaperAccent(accent, deriveShimmer(accent));
			applyWallpaperAccent(theme, accent);
		} catch {
			// The async watcher/read path below safely retries unavailable files.
		}
	}

	private openWatcher(): void {
		if (!this.running || this.watcher !== undefined) return;
		try {
			const fileName = basename(this.accentPath);
			const watcher = this.watchDirectory(dirname(this.accentPath), (eventType, filename) => {
				const changed = filename === null ? undefined : Buffer.isBuffer(filename) ? filename.toString() : filename;
				if (eventType === "change" || eventType === "rename") {
					if (changed === undefined || changed === fileName) this.scheduleRefresh();
				}
			});
			this.watcher = watcher;
			watcher.unref?.();
			watcher.on?.("error", () => {
				watcher.close();
				if (this.watcher === watcher) this.watcher = undefined;
				this.scheduleWatcherRetry();
			});
		} catch {
			this.scheduleWatcherRetry();
		}
	}

	private scheduleRefresh(): void {
		if (!this.running) return;
		if (this.debounceTimer !== undefined) clearTimeout(this.debounceTimer);
		this.debounceTimer = setTimeout(() => {
			this.debounceTimer = undefined;
			void this.refresh();
		}, this.debounceMs);
		unref(this.debounceTimer);
	}

	private scheduleWatcherRetry(): void {
		if (!this.running || this.watchRetryTimer !== undefined) return;
		this.watchRetryTimer = setTimeout(() => {
			this.watchRetryTimer = undefined;
			this.openWatcher();
		}, 1_000);
		unref(this.watchRetryTimer);
	}
}
