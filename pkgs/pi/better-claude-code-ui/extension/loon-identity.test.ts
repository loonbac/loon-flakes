import test from "node:test";
import assert from "node:assert/strict";
import { paletteKeyForThemeName, isLightThemeName } from "./palette.ts";

test("paletteKeyForThemeName resolves to single loon theme", () => {
	assert.equal(paletteKeyForThemeName("loon"), "loon");
	assert.equal(paletteKeyForThemeName(), "loon");
});

test("isLightThemeName returns false for loon theme", () => {
	assert.equal(isLightThemeName("loon"), false);
	assert.equal(isLightThemeName(), false);
});
