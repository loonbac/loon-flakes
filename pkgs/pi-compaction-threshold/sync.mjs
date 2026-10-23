#!/usr/bin/env node
// Keep Pi's compaction threshold constant across every model of a chosen
// context size.
//
// Pi compacts when `contextTokens > contextWindow - reserveTokens`, and it
// accepts the override only as an exact `provider/model` key (the settings
// schema is a record with no wildcards). With the built-in reserve of 16384 a
// 1M model therefore carries ~984k tokens before compacting, and the whole
// prefix is re-sent at the cache-miss price in the meantime.
//
// This tool derives one override per model from the live catalogue so the
// threshold stays put while the catalogue changes. It only ever adds or
// updates entries: a model missing from a partial catalogue keeps the override
// it already had.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const VERSION = "1.0.0";

const DEFAULTS = {
  threshold: 250_000,
  // Below this reserve a small model would lose the headroom it needs to emit
  // a full response before hitting the window; the default 16384 already
  // compacts such a model well below the requested threshold.
  floorReserve: 65_536,
  builtinReserve: 16_384,
};

function usage(stream) {
  stream.write(`Usage: pi-compaction-threshold [options]

Pin Pi's compaction threshold for every model large enough to exceed it.

Options:
  --threshold N       Context tokens to keep before compacting (default ${DEFAULTS.threshold})
  --settings PATH     settings.json to update (default ~/.pi/agent/settings.json)
  --apply             Write the result (default is a dry run)
  --json              Print the computed overrides as JSON
  -V, --version       Show the version
  -h, --help          Show this message
`);
}

function parseArgs(argv) {
  const options = { ...DEFAULTS, apply: false, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = () => {
      const next = argv[i + 1];
      if (next === undefined) throw new Error(`${arg} requires a value`);
      i += 1;
      return next;
    };
    switch (arg) {
      case "--threshold": {
        const raw = Number(value());
        if (!Number.isSafeInteger(raw) || raw <= 0) throw new Error(`invalid --threshold: ${raw}`);
        options.threshold = raw;
        break;
      }
      case "--settings":
        options.settings = value();
        break;
      case "--apply":
        options.apply = true;
        break;
      case "--json":
        options.json = true;
        break;
      case "-V":
      case "--version":
        options.version = true;
        break;
      case "-h":
      case "--help":
        options.help = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }
  options.settings ??= path.join(os.homedir(), ".pi", "agent", "settings.json");
  return options;
}

/** Parse a compact size such as `1M`, `983.6K`, or `65536`. */
export function parseContextTokens(raw) {
  const text = String(raw).trim().toUpperCase();
  const match = /^([\d.]+)([KM])?$/.exec(text);
  if (!match) return Number.NaN;
  const value = Number(match[1]);
  if (!Number.isFinite(value)) return Number.NaN;
  const scale = match[2] === "M" ? 1e6 : match[2] === "K" ? 1e3 : 1;
  return Math.round(value * scale);
}

/**
 * Read the live catalogue from `pi --list-models`.
 *
 * The table is `provider  model  context  max-out  thinking  images`, and a
 * model id may contain `/` or `:` but never whitespace.
 */
export function parseModelTable(table) {
  const models = [];
  for (const line of table.split("\n")) {
    const columns = line.trim().split(/\s+/);
    if (columns.length < 3) continue;
    const [provider, id, context] = columns;
    // The header row and any prose use words where the data has numbers.
    if (provider === "provider" || !/^[\d.]+[KM]?$/i.test(context)) continue;
    const contextWindow = parseContextTokens(context);
    if (!Number.isSafeInteger(contextWindow) || contextWindow <= 0) continue;
    models.push({ provider, id, contextWindow });
  }
  return models;
}

/**
 * Derive the override map for `models`.
 *
 * A model whose window does not exceed the threshold plus the built-in reserve
 * needs no entry: the default already compacts it earlier than requested.
 */
export function computeOverrides(models, { threshold, floorReserve, builtinReserve }) {
  const overrides = {};
  for (const { provider, id, contextWindow } of models) {
    if (contextWindow - builtinReserve <= threshold) continue;
    overrides[`${provider}/${id}`] = {
      reserveTokens: Math.max(floorReserve, contextWindow - threshold),
    };
  }
  return overrides;
}

/** Merge computed overrides over the existing ones without dropping any. */
export function mergeOverrides(existing, computed) {
  return { ...(existing ?? {}), ...computed };
}

/**
 * Write `settings` atomically, keeping the mode of the file it replaces.
 *
 * Pi rewrites settings.json itself, so a partial write must never be visible.
 */
export function writeSettings(target, settings) {
  let mode = 0o600;
  try {
    mode = fs.statSync(target).mode & 0o777;
  } catch {
    // A first activation has no file yet; keep the restrictive default.
  }
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const temporary = `${target}.nix-tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(settings, null, 2)}\n`, { mode });
  fs.renameSync(temporary, target);
  fs.chmodSync(target, mode);
}

function readSettings(target) {
  if (!fs.existsSync(target)) return {};
  return JSON.parse(fs.readFileSync(target, "utf8"));
}

function listModels() {
  const stdout = execFileSync("pi", ["--list-models"], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return parseModelTable(stdout);
}

function main(argv) {
  const options = parseArgs(argv);
  if (options.version) {
    process.stdout.write(`pi-compaction-threshold ${VERSION}\n`);
    return 0;
  }
  if (options.help) {
    usage(process.stdout);
    return 0;
  }

  const models = listModels();
  if (models.length === 0) {
    throw new Error("`pi --list-models` returned no models; refusing to rewrite settings");
  }

  const computed = computeOverrides(models, options);
  const settings = readSettings(options.settings);
  const existing = settings.compaction?.modelOverrides ?? {};
  const merged = mergeOverrides(existing, computed);
  const settingsWithOverrides = {
    ...settings,
    compaction: { ...(settings.compaction ?? {}), modelOverrides: merged },
  };

  const added = Object.keys(computed).filter((key) => !(key in existing)).length;
  const updated = Object.keys(computed).filter(
    (key) => key in existing && existing[key]?.reserveTokens !== computed[key].reserveTokens,
  ).length;

  if (options.json) {
    process.stdout.write(`${JSON.stringify(computed, null, 2)}\n`);
  } else {
    process.stdout.write(
      [
        `models in catalogue : ${models.length}`,
        `threshold           : ${options.threshold.toLocaleString("en-US")} tokens`,
        `overrides computed  : ${Object.keys(computed).length}`,
        `  newly added       : ${added}`,
        `  reserve corrected : ${updated}`,
        `  left untouched    : ${Object.keys(merged).length - Object.keys(computed).length}`,
      ].join("\n") + "\n",
    );
  }

  if (!options.apply) {
    if (!options.json) process.stdout.write("\ndry run: pass --apply to write\n");
    return 0;
  }
  if (added === 0 && updated === 0) {
    if (!options.json) process.stdout.write("\nsettings already up to date\n");
    return 0;
  }
  writeSettings(options.settings, settingsWithOverrides);
  if (!options.json) process.stdout.write(`\nwrote ${options.settings}\n`);
  return 0;
}

// Only run when executed directly, so tests can import the helpers.
if (process.argv[1] && import.meta.url === `file://${path.resolve(process.argv[1])}`) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`pi-compaction-threshold: ${error.message}\n`);
    process.exitCode = 1;
  }
}
