import assert from "node:assert/strict";
import test from "node:test";
import {
	buildWallpaperTheme,
	parseAccentHex,
	deriveShimmer,
	WallpaperAccentSync,
	type RuntimeTheme,
} from "./wallpaper-sync.ts";

test("parseAccentHex and deriveShimmer validate hex colors", () => {
	assert.equal(parseAccentHex("#217168"), "#217168");
	assert.equal(parseAccentHex("  #abcdef  "), "#ABCDEF");
	assert.equal(parseAccentHex("invalid"), undefined);
	assert.equal(parseAccentHex("#123"), undefined);

	const shimmer = deriveShimmer("#217168");
	assert.match(shimmer, /^#[0-9A-F]{6}$/);
	assert.notEqual(shimmer, "#217168");
});

test("buildWallpaperTheme works with Pi 1.0.0 fgAnsi / bgAnsi themes", () => {
	const mockTheme: RuntimeTheme = {
		name: "test-theme",
		fgAnsi: new Map([
			["border", "\x1b[38;2;100;100;100m"],
			["text", "\x1b[38;2;200;200;200m"],
		]),
		bgAnsi: new Map([
			["background", "\x1b[48;2;0;0;0m"],
		]),
		getColorMode: () => "truecolor",
	};

	const themed = buildWallpaperTheme(mockTheme, "#217168");
	assert.equal(themed.fgAnsi?.get("border"), "\x1b[38;2;33;113;104m");
	assert.equal(themed.fgAnsi?.get("borderAccent"), "\x1b[38;2;33;113;104m");
	assert.equal(themed.fgAnsi?.get("borderMuted"), "\x1b[38;2;33;113;104m");
	assert.equal(themed.fgAnsi?.get("claude"), "\x1b[38;2;33;113;104m");
	assert.equal(themed.fgAnsi?.get("scrollbarThumb"), "\x1b[38;2;33;113;104m");
	assert.ok(themed.fgAnsi?.get("claudeShimmer"));
	assert.equal(themed.fgAnsi?.get("text"), "\x1b[38;2;200;200;200m");
});

test("WallpaperAccentSync updates Pi 1.0.0 fgAnsi in place on refresh", async () => {
	const theme: RuntimeTheme = {
		name: "pi-runtime",
		fgAnsi: new Map([
			["border", "\x1b[38;2;0;0;0m"],
			["claude", "\x1b[38;2;0;0;0m"],
		]),
		bgAnsi: new Map(),
		getColorMode: () => "truecolor",
	};

	let fileContent = "#217168";
	let invalidated = false;
	const ui = {
		theme,
		invalidate: () => { invalidated = true; },
		requestRender: () => {},
	};

	const sync = new WallpaperAccentSync({
		accentPath: "/dummy/accent.txt",
		readAccentText: async () => fileContent,
		watchDirectory: () => ({ close: () => {} }),
	});

	await sync.start(ui);
	assert.equal(theme.fgAnsi?.get("border"), "\x1b[38;2;33;113;104m");
	assert.equal(theme.fgAnsi?.get("borderAccent"), "\x1b[38;2;33;113;104m");
	assert.equal(theme.fgAnsi?.get("scrollbarThumb"), "\x1b[38;2;33;113;104m");

	// Change file content to another accent
	fileContent = "#FF5500";
	await sync.refresh();
	assert.equal(theme.fgAnsi?.get("border"), "\x1b[38;2;255;85;0m");
	assert.equal(theme.fgAnsi?.get("borderAccent"), "\x1b[38;2;255;85;0m");
	assert.equal(theme.fgAnsi?.get("scrollbarThumb"), "\x1b[38;2;255;85;0m");

	sync.stop();
});
