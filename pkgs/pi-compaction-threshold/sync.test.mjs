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
  computeOverrides,
  mergeOverrides,
  parseContextTokens,
  parseModelTable,
  writeSettings,
} from "./sync.mjs";

const BASE = { threshold: 250_000, floorReserve: 65_536, builtinReserve: 16_384 };

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
  assert.deepEqual(overrides, { "p/m": { reserveTokens: 750_000 } });
  // The threshold Pi derives is contextWindow - reserveTokens.
  assert.equal(1_000_000 - overrides["p/m"].reserveTokens, 250_000);
});

test("computeOverrides holds the threshold for a model below 1M", () => {
  const overrides = computeOverrides([{ provider: "p", id: "m", contextWindow: 400_000 }], BASE);
  assert.deepEqual(overrides, { "p/m": { reserveTokens: 150_000 } });
  assert.equal(400_000 - overrides["p/m"].reserveTokens, 250_000);
});

test("computeOverrides asks for no entry when the default already fits", () => {
  // A 262.1K model compacts at 245_716 with the built-in reserve, which is
  // earlier than the requested 250k, so an override would only be noise.
  const overrides = computeOverrides([{ provider: "p", id: "m", contextWindow: 262_100 }], BASE);
  assert.deepEqual(overrides, {});
});

test("computeOverrides applies the floor to a model just above the threshold", () => {
  // 300K - 250K would be a 50K reserve; the floor keeps 65_536 so the model
  // can still emit a full response.
  const overrides = computeOverrides([{ provider: "p", id: "m", contextWindow: 300_000 }], BASE);
  assert.deepEqual(overrides, { "p/m": { reserveTokens: 65_536 } });
});

test("computeOverrides upgrades an existing reserve that is smaller", () => {
  const models = [{ provider: "p", id: "m", contextWindow: 1_000_000 }];
  const first = computeOverrides(models, { ...BASE, threshold: 150_000 });
  const second = computeOverrides(models, BASE);
  assert.equal(first["p/m"].reserveTokens, 850_000);
  assert.equal(second["p/m"].reserveTokens, 750_000);
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
