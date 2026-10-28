// Tests for the compaction-threshold synchroniser.
//
// Run with: node --test
//
// Each case pins one observable rule: how a size is parsed, which models get an
// override, what the reserve is, and that a merge never drops an entry.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  OVERFLOW_SAFETY_RATIO,
  computeOverrides,
  mergeOverrides,
  parseContextTokens,
  parseModelTable,
  writeSettings,
} from "./sync.mjs";

const BASE = { safetyRatio: 0.90, floorReserve: 65_536, builtinReserve: 16_384 };

test("OVERFLOW_SAFETY_RATIO is 90% by default", () => {
  assert.equal(OVERFLOW_SAFETY_RATIO, 0.90);
});

test("parseContextTokens reads the compact size Pi prints", () => {
  assert.equal(parseContextTokens("1M"), 1_000_000);
  assert.equal(parseContextTokens("262.1K"), 262_100);
  assert.equal(parseContextTokens("983.6K"), 983_600);
  assert.equal(parseContextTokens("65536"), 65_536);
  assert.equal(parseContextTokens("1.0M"), 1_000_000);
});

test("parseContextTokens rejects a value that is not a size", () => {
  assert.ok(Number.isNaN(parseContextTokens("yes")));
  assert.ok(Number.isNaN(parseContextTokens("")));
  assert.ok(Number.isNaN(parseContextTokens("M")));
});

test("parseModelTable reads provider, id and context window", () => {
  const table = [
    "provider            model                     context  max-out  thinking  images",
    "opencode-go         deepseek-v4.1-flash       1M       393.2K   yes       yes   ",
    "commandcode         deepseek/deepseek-v4-pro  400K     65.5K    yes       no    ",
  ].join("\n");
  const models = parseModelTable(table);
  assert.deepEqual(models, [
    { provider: "opencode-go", id: "deepseek-v4.1-flash", contextWindow: 1_000_000 },
    { provider: "commandcode", id: "deepseek/deepseek-v4-pro", contextWindow: 400_000 },
  ]);
});

test("parseModelTable keeps a model id that contains a colon", () => {
  const table = "infronai  deepseek/deepseek-v4.1-flash:free  1M  393.2K  yes  no";
  assert.deepEqual(parseModelTable(table), [
    { provider: "infronai", id: "deepseek/deepseek-v4.1-flash:free", contextWindow: 1_000_000 },
  ]);
});

test("parseModelTable ignores the header row and prose", () => {
  assert.deepEqual(parseModelTable("provider  model  context"), []);
  assert.deepEqual(parseModelTable("Total: 198 models in 16 providers"), []);
  assert.deepEqual(parseModelTable(""), []);
});

test("computeOverrides keys a 1M model so it compacts at the threshold", () => {
  const overrides = computeOverrides([{ provider: "p", id: "m", contextWindow: 1_000_000 }], BASE);
  assert.deepEqual(overrides, { "p/m": { reserveTokens: 100_000 } });
  // The threshold Pi derives is contextWindow - reserveTokens (90% of 1M = 900k).
  assert.equal(1_000_000 - overrides["p/m"].reserveTokens, 900_000);
});

test("computeOverrides holds the threshold for a model below 1M", () => {
  const overrides = computeOverrides([{ provider: "p", id: "m", contextWindow: 800_000 }], BASE);
  // 90% of 800k = 720k; reserve = 80k > 65_536 floor.
  assert.deepEqual(overrides, { "p/m": { reserveTokens: 80_000 } });
  assert.equal(800_000 - overrides["p/m"].reserveTokens, 720_000);
});

test("computeOverrides asks for no entry when the default already fits", () => {
  // A 100K model compacts at 83_616 with the built-in reserve, which is
  // earlier than the 90% threshold (90k), so an override would only be noise.
  const overrides = computeOverrides([{ provider: "p", id: "m", contextWindow: 100_000 }], BASE);
  assert.deepEqual(overrides, {});
});

test("computeOverrides applies the floor to a model just above the threshold", () => {
  // 400K * 0.90 = 360K; 400K - 360K would be a 40K reserve; the floor keeps 65_536 so the model
  // can still emit a full response.
  const overrides = computeOverrides([{ provider: "p", id: "m", contextWindow: 400_000 }], BASE);
  assert.deepEqual(overrides, { "p/m": { reserveTokens: 65_536 } });
});

test("computeOverrides upgrades an existing reserve that is smaller", () => {
  const models = [{ provider: "p", id: "m", contextWindow: 1_000_000 }];
  const first = computeOverrides(models, { ...BASE, safetyRatio: 0.80 });
  const second = computeOverrides(models, BASE);
  assert.equal(first["p/m"].reserveTokens, 200_000);
  assert.equal(second["p/m"].reserveTokens, 100_000);
});

test("computeOverrides supports explicit threshold override", () => {
  const models = [{ provider: "p", id: "m", contextWindow: 1_000_000 }];
  const overrides = computeOverrides(models, { ...BASE, threshold: 250_000 });
  assert.equal(overrides["p/m"].reserveTokens, 750_000);
  assert.equal(1_000_000 - overrides["p/m"].reserveTokens, 250_000);
});

test("mergeOverrides keeps an entry the catalogue no longer reports", () => {
  const existing = { "gone/model": { reserveTokens: 750_000 }, "p/m": { reserveTokens: 850_000 } };
  const merged = mergeOverrides(existing, { "p/m": { reserveTokens: 750_000 } });
  assert.deepEqual(merged, {
    "gone/model": { reserveTokens: 750_000 },
    "p/m": { reserveTokens: 750_000 },
  });
});

test("mergeOverrides works with no previous overrides", () => {
  assert.deepEqual(mergeOverrides(undefined, { "p/m": { reserveTokens: 1 } }), {
    "p/m": { reserveTokens: 1 },
  });
});

test("writeSettings replaces the file and keeps its permissions", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "compaction-threshold-"));
  const target = path.join(directory, "settings.json");
  fs.writeFileSync(target, '{"theme":"loon"}\n', { mode: 0o600 });

  writeSettings(target, { theme: "loon", compaction: { modelOverrides: {} } });

  assert.deepEqual(JSON.parse(fs.readFileSync(target, "utf8")), {
    theme: "loon",
    compaction: { modelOverrides: {} },
  });
  assert.equal(fs.statSync(target).mode & 0o777, 0o600);
  // No temporary file is left behind.
  assert.deepEqual(fs.readdirSync(directory), ["settings.json"]);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("writeSettings creates a missing file with restrictive permissions", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "compaction-threshold-"));
  const target = path.join(directory, "nested", "settings.json");

  writeSettings(target, { compaction: {} });

  assert.deepEqual(JSON.parse(fs.readFileSync(target, "utf8")), { compaction: {} });
  assert.equal(fs.statSync(target).mode & 0o777, 0o600);
  fs.rmSync(directory, { recursive: true, force: true });
});
