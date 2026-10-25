#!/usr/bin/env node

/**
 * Antigravity Account Keeper
 *
 * Keeps Pi's Google Antigravity accounts healthy:
 *
 * - Default mode (no flags): periodically renews expiring, inactive accounts so
 *   that quota failover never lands on an account with a dead refresh token.
 * - `--prefer <email>`: ensures the preferred account is the active one, but only
 *   when it can produce a usable token and offers every required model. This stops
 *   an automatic failover from leaving the session on an account that lacks the
 *   models in use.
 * - Required-model verification: with ANTIGRAVITY_REQUIRED_MODELS set, checks the
 *   active account's catalog and fails (exit 2) when a required model is missing.
 *
 * Credentials are read from the runtime state and are never printed, logged or
 * written anywhere except back to the state files that already hold them.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const DEFAULT_RENEWAL_WINDOW_MS = 10 * 60 * 1000; // 10 minutes
const DEFAULT_SKEW_MS = 5 * 60 * 1000; // 5 minutes skew
const ACCOUNTS_FILENAME = "antigravity-accounts.json";
const AUTH_FILENAME = "auth.json";
const LOG_FILENAME = "antigravity-keeper.log";
const REQUEST_TIMEOUT_MS = 15000;

const DEFAULT_MODELS_URL =
  "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels";

// The models endpoint answers 403 PERMISSION_DENIED without this exact CLI
// fingerprint, so it must match pi-antigravity's antigravityHeaders().
const MODELS_USER_AGENT =
  "antigravity/cli/1.4.0 (aidev_client; os_type=linux; arch=amd64; cl=982146307; auth_method=consumer)";

// Model ids may carry an effort suffix; "claude-opus-5-5" must match
// "claude-opus-5-5-high" and friends.
const EFFORT_SUFFIX_RE = /-(high|medium|low)$/;

export function resolveAgentDir(env = process.env) {
  return env.PI_CODING_AGENT_DIR || path.join(os.homedir(), ".pi", "agent");
}

export function resolveAccountsPath(env = process.env) {
  return env.ANTIGRAVITY_ACCOUNTS_FILE || path.join(resolveAgentDir(env), ACCOUNTS_FILENAME);
}

export function resolveAuthPath(env = process.env) {
  return env.ANTIGRAVITY_AUTH_FILE || path.join(resolveAgentDir(env), AUTH_FILENAME);
}

export function resolveLogPath(env = process.env) {
  return env.ANTIGRAVITY_LOG_FILE || path.join(resolveAgentDir(env), LOG_FILENAME);
}

export function resolveModelsUrl(env = process.env) {
  return env.ANTIGRAVITY_MODELS_URL || DEFAULT_MODELS_URL;
}

export function resolveOAuthPath(env = process.env) {
  return (
    env.ANTIGRAVITY_OAUTH_PATH ||
    path.join(
      resolveAgentDir(env),
      "npm",
      "node_modules",
      "pi-antigravity",
      "src",
      "auth",
      "oauth.ts",
    )
  );
}

function parseConst(content, constName) {
  // 1. Direct string literal: export const NAME = "..."
  const directMatch = content.match(
    new RegExp(`export\\s+const\\s+${constName}\\s*=\\s*["\x27]([^"\x27]+)["\x27]`),
  );
  if (directMatch) return directMatch[1];

  // 2. atob(...) with concatenated string literals
  const atobMatch = content.match(
    new RegExp(`export\\s+const\\s+${constName}\\s*=[^;]*?atob\\s*\\(([^;]+?)\\)`, "s"),
  );
  if (atobMatch) {
    const stringParts = [...atobMatch[1].matchAll(/["\x27]([^"\x27]*)["\x27]/g)]
      .map((m) => m[1])
      .join("");
    if (stringParts) {
      try {
        return atob(stringParts);
      } catch {}
    }
  }

  // 3. Fallback string literal after ||
  const fallbackMatch = content.match(
    new RegExp(`export\\s+const\\s+${constName}\\s*=[^;]*?\\|\\|\\s*["\x27]([^"\x27]+)["\x27]`),
  );
  if (fallbackMatch) return fallbackMatch[1];

  return undefined;
}

export function resolveOAuthConstants(env = process.env, customOauthPath = null) {
  // Only prefixed names are trusted. A bare TOKEN_URL in the inherited environment
  // would let any process that can set it redirect this exchange and receive the
  // Antigravity refresh token, so the unprefixed variants are ignored on purpose.
  let tokenUrl = env.ANTIGRAVITY_TOKEN_URL;
  let clientId = env.ANTIGRAVITY_CLIENT_ID;
  let clientSecret = env.ANTIGRAVITY_CLIENT_SECRET;

  if (tokenUrl && clientId && clientSecret) {
    return { tokenUrl, clientId, clientSecret };
  }

  const oauthPath = customOauthPath || resolveOAuthPath(env);
  if (fs.existsSync(oauthPath)) {
    const content = fs.readFileSync(oauthPath, "utf8");

    if (!tokenUrl) {
      const match = content.match(/export\s+const\s+TOKEN_URL\s*=\s*["\x27]([^"\x27]+)["\x27]/);
      if (match) tokenUrl = match[1];
    }
    if (!clientId) {
      clientId = parseConst(content, "CLIENT_ID");
    }
    if (!clientSecret) {
      clientSecret = parseConst(content, "CLIENT_SECRET");
    }
  }

  const missing = [];
  if (!tokenUrl) missing.push("TOKEN_URL");
  if (!clientId) missing.push("CLIENT_ID");
  if (!clientSecret) missing.push("CLIENT_SECRET");

  if (missing.length > 0) {
    throw new Error(`Failed to resolve OAuth constants: missing ${missing.join(", ")}`);
  }

  return { tokenUrl, clientId, clientSecret };
}

export function parseAccountsFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return { exists: false, store: { version: 1, accounts: {} } };
  }
  const raw = fs.readFileSync(filePath, "utf8");
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || parsed.version !== 1) {
    throw new Error(`Invalid accounts store format in ${filePath}`);
  }
  if (!parsed.accounts || typeof parsed.accounts !== "object" || Array.isArray(parsed.accounts)) {
    parsed.accounts = {};
  }
  return { exists: true, store: parsed };
}

/**
 * Read a single account from the store by email, account id or map key.
 */
export function findAccountEntry(store, selector) {
  if (!store || !store.accounts || typeof store.accounts !== "object") return null;
  if (selector && Object.hasOwn(store.accounts, selector)) {
    return { key: selector, account: store.accounts[selector] };
  }
  const wanted = String(selector ?? "").trim().toLowerCase();
  if (!wanted) return null;
  for (const [key, account] of Object.entries(store.accounts)) {
    if (!account || typeof account !== "object") continue;
    const email = typeof account.email === "string" ? account.email.toLowerCase() : "";
    const accountId = typeof account.accountId === "string" ? account.accountId.toLowerCase() : "";
    if (email === wanted || accountId === wanted || key.toLowerCase() === wanted) {
      return { key, account };
    }
  }
  return null;
}

/** Whether `key` is the store's active account, resolving aliases like findAccountEntry. */
export function isActiveAccount(store, key) {
  const active = store?.activeAccountId ? findAccountEntry(store, store.activeAccountId) : null;
  return active ? active.key === key : false;
}

export function parseRequiredModels(value) {
  if (typeof value !== "string") return [];
  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

/** Strip a trailing effort suffix so a required base id matches suffixed ids. */
export function baseModelId(id) {
  return String(id).trim().toLowerCase().replace(EFFORT_SUFFIX_RE, "");
}

/**
 * Extract runtime model ids from a fetchAvailableModels payload, tolerating both
 * `{ models: { <id>: {...} } }` and list shapes.
 */
export function extractModelIds(payload) {
  const ids = new Set();

  if (typeof payload === "string") {
    if (payload) ids.add(payload);
    return ids;
  }

  const root =
    payload && typeof payload === "object" && !Array.isArray(payload) ? payload.models ?? payload : payload;

  const collectObjectEntry = (key, value) => {
    if (typeof value === "string") {
      if (value) ids.add(value);
      else if (key) ids.add(key);
      return;
    }
    if (value && typeof value === "object") {
      // The live payload is an object map whose KEY is the selectable id
      // (`claude-opus-5-5-high`) while the value carries the internal enum in
      // `model` (`MODEL_PLACEHOLDER_M402`). Keep the key: it is the id a caller
      // can select, and the enum never matches a model name.
      if (typeof key === "string" && key) ids.add(key);
      const candidate = value.id ?? value.name ?? value.model;
      if (typeof candidate === "string" && candidate) ids.add(candidate);
      return;
    }
    if (typeof key === "string" && key) ids.add(key);
  };

  if (Array.isArray(root)) {
    for (const entry of root) {
      if (typeof entry === "string") {
        if (entry) ids.add(entry);
      } else if (entry && typeof entry === "object") {
        const candidate = entry.id ?? entry.name ?? entry.model;
        if (typeof candidate === "string" && candidate) ids.add(candidate);
      }
    }
  } else if (root && typeof root === "object") {
    for (const [key, value] of Object.entries(root)) {
      collectObjectEntry(key, value);
    }
  }

  return ids;
}

export function findMissingModels(availableIds, requiredModels) {
  const ids = [...availableIds].map((id) => String(id).trim().toLowerCase());
  // Directional: a suffixed requirement needs that exact id; a base requirement
  // accepts any available id sharing its base (never the reverse).
  return requiredModels.filter((model) => {
    const wanted = String(model).trim().toLowerCase();
    const wantsExact = EFFORT_SUFFIX_RE.test(wanted);
    return !ids.some((id) => (wantsExact ? id === wanted : baseModelId(id) === wanted));
  });
}

/**
 * Query the active account catalog. Callers decide whether a failure is fatal.
 */
export async function fetchAvailableModelIds({ access, projectId, modelsUrl, fetchImpl = fetch }) {
  if (typeof access !== "string" || !access) {
    throw new Error("model check requires an access token");
  }
  const response = await fetchImpl(modelsUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${access}`,
      "Content-Type": "application/json",
      "User-Agent": MODELS_USER_AGENT,
    },
    body: JSON.stringify({ project: projectId }),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`models endpoint returned HTTP ${response.status}`);
  }
  return extractModelIds(await response.json());
}

function readAuthFile(authPath) {
  if (!fs.existsSync(authPath)) return {};
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(authPath, "utf8"));
  } catch {
    throw new Error(`Refusing to overwrite unreadable ${path.basename(authPath)}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`Refusing to overwrite unreadable ${path.basename(authPath)}`);
  }
  return parsed;
}

/**
 * Mirror pi-antigravity's writeActiveCredential(): replace only the "antigravity"
 * key, keep every other Pi provider entry byte-compatible.
 */
export function writeActiveCredential(authPath, account) {
  const auth = readAuthFile(authPath);
  auth.antigravity = {
    type: "oauth",
    email: account.email,
    access: account.access,
    refresh: account.refresh,
    expires: account.expires,
    projectId: account.projectId,
  };
  writeAtomicJson(authPath, auth);
}

/** Best effort by contract: a log failure must never abort the caller or keep a
 * rotated refresh token from reaching the persistence block. */
export function writeAccountLog(logPath, email, result, minutesUntilExpiry) {
  try {
    appendAccountLog(logPath, email, result, minutesUntilExpiry);
  } catch {}
}

function appendAccountLog(logPath, email, result, minutesUntilExpiry) {
  const dir = path.dirname(logPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  const line = `[${new Date().toISOString()}] email=${email} result=${result} minutes_until_expiry=${minutesUntilExpiry}\n`;
  const existed = fs.existsSync(logPath);
  fs.appendFileSync(logPath, line, { encoding: "utf8", mode: 0o600 });
  if (!existed) {
    try {
      fs.chmodSync(logPath, 0o600);
    } catch {}
  }
}

export function writeAtomicJson(filePath, data, expectedHash = null) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  const tempPath = path.join(dir, `${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tempPath, `${JSON.stringify(data, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  fs.chmodSync(tempPath, 0o600);
  // Last-moment compare-and-swap: the caller's hash was taken before it applied its
  // fields, so a foreign write since then would be dropped by this rename. Checking
  // here shrinks the loss window to a single syscall instead of the whole apply.
  if (expectedHash !== null && storeHash(filePath) !== expectedHash) {
    try { fs.unlinkSync(tempPath); } catch {}
    return false;
  }
  fs.renameSync(tempPath, filePath);
  fs.chmodSync(filePath, 0o600);
  return true;
}

/**
 * Bounded compare-and-retry over the accounts store.
 *
 * The store has two writers: this keeper and pi-antigravity, which does not take
 * any lock of ours. A lock file would therefore exclude only other keeper
 * instances while doing nothing against the writer that actually races us, so it
 * is gone. Instead every attempt re-reads the store immediately before the atomic
 * rename, applies only keeper-owned fields onto that copy, and verifies they
 * landed; a concurrent write in the read->rename window fails verification and the
 * attempt is retried, which is what preserves foreign fields and an
 * `activeAccountId` moved by a quota failover. The attempt count is small and
 * fixed so a pathological writer cannot pin the process, and the backoff keeps two
 * keepers from lock-stepping. A detected foreign write is retried, never dropped;
 * the residual window between the final re-read and the rename cannot be closed
 * without cooperation from pi-antigravity, so exhausted attempts report failure.
 *
 * `apply(store)` mutates the keeper-owned fields and returns `{ dirty, skipped,
 * error, verified }`: `dirty` says whether anything must be committed, `skipped`
 * lists accounts left untouched (e.g. one that became active mid-flight), `error`
 * aborts with no write at all, and `verified(afterStore)` confirms a re-read holds
 * the values we wrote.
 */
const STORE_WRITE_ATTEMPTS = 4;
const STORE_WRITE_BACKOFF_MS = 20;

function storeHash(accountsPath) {
  try { return crypto.createHash("sha256").update(fs.readFileSync(accountsPath)).digest("hex"); }
  catch { return "absent"; }
}

export async function withStoreRetry(accountsPath, apply) {
  let lastOutcome = { dirty: false, skipped: [], verified: () => true };
  for (let attempt = 0; attempt < STORE_WRITE_ATTEMPTS; attempt++) {
    const beforeHash = storeHash(accountsPath);
    const { exists, store } = parseAccountsFile(accountsPath);
    const target = exists ? store : { version: 1, accounts: {} };
    if (!target.accounts || typeof target.accounts !== "object") target.accounts = {};

    const outcome = apply(target);
    lastOutcome = outcome;
    if (outcome.error) return { ok: false, error: outcome.error, outcome };
    if (!outcome.dirty) return { ok: true, outcome };

    // Compare-and-swap before the rename: a foreign write since our read would be
    // silently dropped by committing this copy, so retry instead.
    if (beforeHash !== storeHash(accountsPath)) {
      if (attempt < STORE_WRITE_ATTEMPTS - 1) {
        await new Promise((resolve) => setTimeout(resolve, STORE_WRITE_BACKOFF_MS));
      }
      continue;
    }

    let committed = false;
    try {
      committed = writeAtomicJson(accountsPath, target, beforeHash);
    } catch {
      // Verification below decides whether to retry.
    }

    const after = parseAccountsFile(accountsPath);
    const afterStore = after.exists ? after.store : { version: 1, accounts: {} };
    // A store that no longer matches the copy we wrote means the commit was partial or
    // a foreign writer landed in between. Neither is success, so retry instead of
    // reporting a write this keeper cannot stand behind.
    const matchesCommit = committed && JSON.stringify(afterStore) === JSON.stringify(target);
    if (matchesCommit && outcome.verified(afterStore)) return { ok: true, outcome };

    if (attempt < STORE_WRITE_ATTEMPTS - 1) {
      await new Promise((resolve) => setTimeout(resolve, STORE_WRITE_BACKOFF_MS));
    }
  }
  return { ok: false, outcome: lastOutcome };
}

/** Healing auth.json from the store at start is what makes a partial state converge. */
function selfHealCredential({ accountsPath, authPath, logPath }) {
  try {
    const { exists, store } = parseAccountsFile(accountsPath);
    const entry =
      exists && store.activeAccountId ? findAccountEntry(store, store.activeAccountId) : null;
    if (!entry) return;
    const current = readAuthFile(authPath).antigravity;
    if (current && findAccountEntry(store, current.email)?.key === entry.key) return;

    // A missing file is healed too: the store pointer only exists because Pi logged in,
    // so an absent mirror means an interrupted activation, not a fresh install. Returning
    // early here would leave the session on an account whose credential was never written
    // while systemd reported success.
    writeActiveCredential(authPath, entry.account);
    writeAccountLog(logPath, accountEmail(entry.account, entry.key), "healed", 0);
  } catch {
    // A heal never fails the run.
  }
}

async function requestAccessToken({
  tokenUrl,
  clientId,
  clientSecret,
  refreshToken,
  skewMs = DEFAULT_SKEW_MS,
  fetchImpl = fetch,
}) {
  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: refreshToken,
    grant_type: "refresh_token",
  }).toString();

  const response = await fetchImpl(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    // A hung endpoint must not pin a unit forever.
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });

  if (!response.ok) {
    throw new Error(`token endpoint returned HTTP ${response.status}`);
  }

  const data = await response.json();
  if (!data || typeof data.access_token !== "string" || !data.access_token) {
    throw new Error("token endpoint returned no access token");
  }

  const expiresInSec = typeof data.expires_in === "number" ? data.expires_in : 3600;
  return {
    access: data.access_token,
    refresh:
      typeof data.refresh_token === "string" && data.refresh_token.trim().length > 0
        ? data.refresh_token
        : null,
    expires: Date.now() + expiresInSec * 1000 - skewMs,
  };
}

function minutesUntil(expires, now) {
  return typeof expires === "number" ? Math.round((expires - now) / 60000) : 0;
}

function accountEmail(account, fallback) {
  return (
    (typeof account?.email === "string" && account.email) ||
    (typeof account?.accountId === "string" && account.accountId) ||
    fallback ||
    "unknown"
  );
}

/**
 * Renew expiring inactive accounts. Never touches activeAccountId.
 */
export async function renewAccounts(options = {}) {
  const env = options.env || process.env;
  const accountsPath = options.accountsPath || resolveAccountsPath(env);
  const logPath = options.logPath || resolveLogPath(env);
  const renewalWindowMs =
    Number(env.ANTIGRAVITY_RENEWAL_WINDOW_MS) || DEFAULT_RENEWAL_WINDOW_MS;
  const skewMs = Number(env.ANTIGRAVITY_SKEW_MS) || DEFAULT_SKEW_MS;

  const { exists, store } = parseAccountsFile(accountsPath);
  if (!exists) {
    return { status: "noop", renewed: 0, failed: 0 };
  }

  const now = Date.now();
  const accountsToRenew = [];

  for (const [key, account] of Object.entries(store.accounts)) {
    if (!account || typeof account !== "object") continue;
    if (typeof account.refresh !== "string" || !account.refresh.trim()) continue;
    // The active account is owned by pi-antigravity, which refreshes it on every use
    // (ensureFresh, 5 minute skew). Renewing it here would race the plugin for the
    // same refresh token, and a lost write can resurrect a token Google already
    // rotated. The keeper exists for the accounts nothing else touches.
    if (isActiveAccount(store, key)) continue;

    const expires = account.expires;
    const isExpiring = typeof expires !== "number" || expires <= now + renewalWindowMs;
    if (isExpiring) {
      accountsToRenew.push({ key, account });
    }
  }

  if (accountsToRenew.length === 0) {
    return { status: "noop", renewed: 0, failed: 0 };
  }

  const { tokenUrl, clientId, clientSecret } = resolveOAuthConstants(env, options.oauthPath);

  let renewedCount = 0;
  let failedCount = 0;
  const renewed = new Map();

  for (const { key, account } of accountsToRenew) {
    const minutesUntilExpiry = minutesUntil(account.expires, now);
    const email = accountEmail(account);
    // Kept so the persistence step can tell our rotation apart from one made by the
    // plugin while the exchange was in flight.
    const previousRefresh = account.refresh;

    try {
      const token = await requestAccessToken({
        tokenUrl,
        clientId,
        clientSecret,
        refreshToken: account.refresh,
        skewMs,
      });

      account.access = token.access;
      account.expires = token.expires;
      if (token.refresh) {
        account.refresh = token.refresh;
      }
      renewed.set(key, {
        email,
        access: account.access,
        expires: account.expires,
        refresh: account.refresh,
        previousRefresh,
        minutesUntilExpiry,
      });

      // Logged only after the token is persisted: a success line for a rotation that was
      // never stored is exactly the misleading observability this guards against.
      renewedCount++;
    } catch {
      writeAccountLog(logPath, email, "failed", minutesUntilExpiry);
      failedCount++;
    }
  }

  let persistFailed = false;
  if (renewed.size > 0) {
    const result = await withStoreRetry(accountsPath, (target) => {
      const skipped = [];
      const adopted = [];
      const written = new Map();
      for (const [key, values] of renewed) {
        const targetAccount = target.accounts[key];
        if (!targetAccount || typeof targetAccount !== "object") continue;
        // The account may have become active while the refresh was in flight. If the
        // stored token is no longer the one we exchanged, pi-antigravity rotated it as
        // well and its value is the newer one, so ours must not win. If it is still the
        // one we exchanged, we hold the only valid replacement: dropping it now leaves
        // the account unable to renew at all, which is the failure this block prevents.
        if (isActiveAccount(target, key)) {
          if (targetAccount.refresh !== values.previousRefresh) {
            skipped.push(values);
            continue;
          }
          adopted.push(values);
        }
        targetAccount.access = values.access;
        targetAccount.expires = values.expires;
        if (values.refresh) targetAccount.refresh = values.refresh;
        written.set(key, values);
      }
      return {
        dirty: written.size > 0,
        skipped,
        adopted,
        writtenKeys: [...written.keys()],
        verified: (after) => {
          for (const [key, values] of written) {
            const account = after.accounts?.[key];
            if (!account || account.access !== values.access || account.expires !== values.expires) {
              return false;
            }
            if (values.refresh && account.refresh !== values.refresh) return false;
          }
          return true;
        },
      };
    });

    for (const values of result.outcome.skipped ?? []) {
      writeAccountLog(logPath, values.email, "skip-now-active", values.minutesUntilExpiry ?? 0);
    }
    if (!result.ok) {
      writeAccountLog(logPath, "keeper", "store-write-unverified", 0);
      persistFailed = true;
    } else {
      // One line per account whose rotated token is now on disk. This is the only place
      // a renewal may claim success, so it can never describe a token that was dropped.
      const adoptedKeys = new Set((result.outcome.adopted ?? []).map((values) => values.email));
      for (const key of result.outcome.writtenKeys ?? []) {
        const values = renewed.get(key);
        if (!values) continue;
        writeAccountLog(
          logPath,
          values.email,
          adoptedKeys.has(values.email) ? "ok-active" : "ok",
          values.minutesUntilExpiry ?? 0,
        );
      }
    }
  }

  return {
    status: failedCount > 0 ? "partial" : "ok",
    renewed: renewedCount,
    failed: failedCount,
    persistFailed,
  };
}

/**
 * Verify the active account offers every required model. Returns exit 0 when the
 * catalog is unavailable (offline must not break the session) and exit 2 when a
 * required model is genuinely missing.
 */
export async function verifyActiveModels(options = {}) {
  const accountsPath = options.accountsPath;
  const logPath = options.logPath;
  const modelsUrl = options.modelsUrl;
  const requiredModels = options.requiredModels || [];
  const fetchImpl = options.fetchImpl || fetch;

  const { exists, store } = parseAccountsFile(accountsPath);
  const activeEntry = exists && store.activeAccountId ? findAccountEntry(store, store.activeAccountId) : null;
  if (!activeEntry) {
    writeAccountLog(logPath, "unknown", "no-active-account", 0);
    return { status: "noop", exitCode: 0, result: "no-active-account" };
  }

  const { account } = activeEntry;
  const email = accountEmail(account);
  const now = Date.now();
  const minutesUntilExpiry = minutesUntil(account.expires, now);

  let availableIds;
  try {
    availableIds = await fetchAvailableModelIds({
      access: account.access,
      projectId: account.projectId,
      modelsUrl,
      fetchImpl,
    });
  } catch {
    writeAccountLog(logPath, email, "model-check-unavailable", minutesUntilExpiry);
    // An unverifiable requirement is not a satisfied one: a oneshot that reports
    // success here would leave the session on an account nobody checked.
    return { status: "unavailable", exitCode: 3, result: "model-check-unavailable" };
  }

  const missing = findMissingModels(availableIds, requiredModels);
  if (missing.length > 0) {
    writeAccountLog(logPath, email, `missing-model:${missing[0]}`, minutesUntilExpiry);
    return { status: "missing-model", exitCode: 2, result: `missing-model:${missing[0]}` };
  }

  writeAccountLog(logPath, email, "ok", minutesUntilExpiry);
  return { status: "ok", exitCode: 0, result: "ok" };
}

/**
 * Ensure the preferred account is active, but only when it can produce a usable
 * token and offers every required model. On any unmet requirement the state is
 * left completely untouched.
 */
export async function preferAccount(options = {}) {
  const env = options.env || process.env;
  const preferred = String(options.preferred ?? "").trim();
  const requiredModels = options.requiredModels || [];
  const accountsPath = options.accountsPath;
  const authPath = options.authPath;
  const logPath = options.logPath;
  const modelsUrl = options.modelsUrl;
  const skewMs = Number(env.ANTIGRAVITY_SKEW_MS) || DEFAULT_SKEW_MS;
  const fetchImpl = options.fetchImpl || fetch;

  const { exists, store } = parseAccountsFile(accountsPath);
  if (!exists) {
    // A oneshot must not report success when it cannot reach the store it was told to use.
    writeAccountLog(logPath, preferred, "preferred-account-missing", 0);
    process.stderr.write("antigravity-account-keeper: accounts store not found; cannot activate the preferred account\n");
    return { status: "error", exitCode: 1, result: "preferred-account-missing" };
  }

  const entry = findAccountEntry(store, preferred);
  if (!entry) {
    // A oneshot must not report success without activating the requested account.
    writeAccountLog(logPath, preferred, "preferred-account-missing", 0);
    process.stderr.write("antigravity-account-keeper: preferred account not found in accounts store\n");
    return { status: "error", exitCode: 1, result: "preferred-account-missing" };
  }

  const { key, account } = entry;
  const email = accountEmail(account, preferred);
  const now = Date.now();
  const minutesUntilExpiry = minutesUntil(account.expires, now);

  const isActive = isActiveAccount(store, key);

  // The active account is owned by pi-antigravity; never race its refresh. For the
  // preferred account we must have a usable token, so refresh it when needed.
  let access = typeof account.access === "string" ? account.access : "";
  let refreshed = null;
  const tokenStale = !access || typeof account.expires !== "number" || account.expires <= now + skewMs;
  if (!isActive && tokenStale) {
    if (typeof account.refresh !== "string" || !account.refresh.trim()) {
      writeAccountLog(logPath, email, "refresh-failed", minutesUntilExpiry);
      return { status: "error", exitCode: 1, result: "refresh-failed" };
    }
    try {
      const { tokenUrl, clientId, clientSecret } = resolveOAuthConstants(env, options.oauthPath);
      refreshed = await requestAccessToken({
        tokenUrl,
        clientId,
        clientSecret,
        refreshToken: account.refresh,
        skewMs,
        fetchImpl,
      });
      access = refreshed.access;
    } catch {
      writeAccountLog(logPath, email, "refresh-failed", minutesUntilExpiry);
      return { status: "error", exitCode: 1, result: "refresh-failed" };
    }

    // Google may rotate the refresh token; persist it before any early return,
    // unless this account became active mid-flight (the plugin then owns it).
    const early = await withStoreRetry(accountsPath, (target) => {
      const fresh = target.accounts[key];
      if (!fresh || typeof fresh !== "object") {
        return { dirty: false, skipped: [], verified: () => true };
      }
      if (isActiveAccount(target, key)) {
        return { dirty: false, skipped: [email], verified: () => true };
      }
      fresh.access = refreshed.access;
      fresh.expires = refreshed.expires;
      if (refreshed.refresh) fresh.refresh = refreshed.refresh;
      return {
        dirty: true,
        skipped: [],
        verified: (after) => {
          const account = after.accounts?.[key];
          if (!account || account.access !== refreshed.access || account.expires !== refreshed.expires) {
            return false;
          }
          return !refreshed.refresh || account.refresh === refreshed.refresh;
        },
      };
    });
    for (const who of early.outcome.skipped) {
      writeAccountLog(logPath, who, "skip-now-active", minutesUntilExpiry);
    }
    if (!early.ok) {
      writeAccountLog(logPath, email, "store-write-unverified", minutesUntilExpiry);
      return { status: "error", exitCode: 1, result: "store-write-unverified" };
    }
  }

  if (requiredModels.length > 0) {
    if (isActive && tokenStale) {
      // Already the active account, and the stored token has expired. The plugin owns
      // that token and refreshes it lazily on first use; refreshing it here would race
      // that refresh, and a lost write can resurrect a token Google already rotated.
      // There is no leadership left to assert (we are already on this account) and no
      // usable credential to verify with, so report the situation plainly instead of
      // failing a unit that resolves itself as soon as the account is used.
      // A stale token is not a verified capability: the catalogue was never queried, so
      // the requirement is unproven. No caller may read this as success;
      // `ensureCompatibleAccount` uses the result string to look for a verifiable one.
      writeAccountLog(logPath, email, "active-token-stale", minutesUntilExpiry);
      return {
        status: "unverifiable",
        exitCode: 3,
        result: "model-check-unavailable:active-token-stale",
      };
    }

    let availableIds;
    try {
      availableIds = await fetchAvailableModelIds({
        access,
        projectId: account.projectId,
        modelsUrl,
        fetchImpl,
      });
    } catch {
      writeAccountLog(logPath, email, "model-check-unavailable", minutesUntilExpiry);
      // Refuse to claim leadership we could not verify (see verifyActiveModels).
      return { status: "unavailable", exitCode: 3, result: "model-check-unavailable" };
    }

    const missing = findMissingModels(availableIds, requiredModels);
    if (missing.length > 0) {
      // Never leave the session on an account without the models in use.
      writeAccountLog(logPath, email, `missing-model:${missing[0]}`, minutesUntilExpiry);
      return { status: "missing-model", exitCode: 2, result: `missing-model:${missing[0]}` };
    }
  }

  if (isActive) {
    writeAccountLog(logPath, email, "ok", minutesUntilExpiry);
    return { status: "ok", exitCode: 0, result: "ok" };
  }

  // Two files, no shared transaction: converge. Preflight, commit `activeAccountId`
  // + tokens, then mirror the committed snapshot; selfHealCredential() heals a crash.
  try {
    readAuthFile(authPath);
  } catch {
    writeAccountLog(logPath, email, "credential-write-failed", minutesUntilExpiry);
    process.stderr.write("antigravity-account-keeper: credential write failed; store unchanged\n");
    return { status: "error", exitCode: 1, result: "credential-write-failed" };
  }

  let previousActiveId = null, snapshot = null;
  const activation = await withStoreRetry(accountsPath, (target) => {
    const freshEntry = findAccountEntry(target, key);
    if (!freshEntry || typeof freshEntry.account !== "object") {
      return { dirty: false, skipped: [], verified: () => true, error: "preferred-account-missing" };
    }
    const targetAccount = freshEntry.account;
    previousActiveId = target.activeAccountId ?? null;

    // If the account became active while we were working, pi-antigravity owns its
    // token fields, so mirror its fresh snapshot instead of our older result.
    const nowActive = isActiveAccount(target, key);
    let wroteTokens = false;
    if (!nowActive && refreshed) {
      targetAccount.access = refreshed.access;
      targetAccount.expires = refreshed.expires;
      if (refreshed.refresh) targetAccount.refresh = refreshed.refresh;
      wroteTokens = true;
    }

    targetAccount.lastUsedAt = now;
    target.activeAccountId = key;
    snapshot = { ...targetAccount };
    return {
      dirty: true,
      skipped: [],
      verified: (after) => {
        if (!isActiveAccount(after, key)) return false;
        if (!wroteTokens) return true;
        const account = after.accounts?.[key];
        if (!account || account.access !== refreshed.access || account.expires !== refreshed.expires) {
          return false;
        }
        return !refreshed.refresh || account.refresh === refreshed.refresh;
      },
    };
  });

  if (!activation.ok) {
    if (activation.error === "preferred-account-missing") {
      writeAccountLog(logPath, email, "preferred-account-missing", minutesUntilExpiry);
      process.stderr.write("antigravity-account-keeper: preferred account vanished from accounts store\n");
    } else {
      writeAccountLog(logPath, email, "store-write-unverified", minutesUntilExpiry);
    }
    return { status: "error", exitCode: 1, result: activation.error || "store-write-unverified" };
  }

  try {
    writeActiveCredential(authPath, snapshot);
  } catch {
    // Compensate: restore the previous pointer; never undo a concurrent failover.
    const restored = await withStoreRetry(accountsPath, (t) => {
      const ours = isActiveAccount(t, key);
      if (ours) t.activeAccountId = previousActiveId ?? undefined;
      return { dirty: ours, skipped: [], verified: (a) => (a.activeAccountId ?? null) === previousActiveId };
    });
    writeAccountLog(logPath, email, "credential-write-failed", minutesUntilExpiry);
    process.stderr.write(`antigravity-account-keeper: credential write failed; active account ${restored.ok && restored.outcome.dirty ? "restored" : "could not be restored"}\n`);
    return { status: "error", exitCode: 1, result: "credential-write-failed" };
  }
  writeAccountLog(logPath, email, "activated", minutesUntilExpiry);
  return { status: "activated", exitCode: 0, result: "activated" };
}

/**
 * Keep the session on an account that offers every required model without pinning
 * any account by name. The active account is verified first and, only when it lacks
 * a required model, another account that covers them is activated. Quota failover
 * stays with the plugin: a capability gap is the only thing this moves.
 */
export async function ensureCompatibleAccount(options = {}) {
  const { accountsPath } = options;
  const requiredModels = options.requiredModels || [];
  // Without a requirement there is nothing to prove and nothing to move: renewal mode
  // owns that case, so stay inert instead of inventing a model id to report.
  if (requiredModels.length === 0) {
    return { status: "noop", exitCode: 0, result: "no-active-account" };
  }
  const { exists, store } = parseAccountsFile(accountsPath);
  const keys = exists && store.accounts && typeof store.accounts === "object" ? Object.keys(store.accounts) : [];
  const activeEntry = exists && store.activeAccountId ? findAccountEntry(store, store.activeAccountId) : null;
  const activeKey = activeEntry ? activeEntry.key : null;

  const STALE = "model-check-unavailable:active-token-stale";
  let current = null;
  let staleActive = false;

  if (activeKey) {
    current = await preferAccount({ ...options, preferred: activeKey });
    if (current.exitCode === 0) return current;
    // Two findings justify trying another account: the active one lacks a required
    // model, or its own token is stale so its capability cannot be checked at all. Any
    // other failure (missing account, unreachable catalogue) stays the answer, because
    // moving would hide it.
    staleActive = current.result === STALE;
    if (!staleActive && !String(current.result || "").startsWith("missing-model")) return current;
  }

  // Preferring a stale account above never reached the catalogue, so a different
  // account with a usable token is both verifiable and a better place for the session.
  for (const key of keys) {
    if (key === activeKey) continue;
    const other = await preferAccount({ ...options, preferred: key });
    if (other.exitCode === 0) return other;
    if (other.result === STALE) staleActive = true;
    else current = other;
  }

  if (current && current.exitCode !== 0) return current;

  // Nothing was activated and nothing verified: success here would let a oneshot report
  // a requirement it never checked, so fail with the most precise reason available.
  if (staleActive) {
    process.stderr.write(
      "antigravity-account-keeper: no account could be verified; the active token is stale\n",
    );
    return { status: "unverifiable", exitCode: 3, result: STALE };
  }
  process.stderr.write(
    `antigravity-account-keeper: no account serves ${requiredModels.join(",")}\n`,
  );
  return {
    status: "unverifiable",
    exitCode: 2,
    result: `missing-model:${requiredModels[0]}`,
  };
}

/**
 * Mode dispatcher:
 * - preferred account set -> prefer flow (which also verifies required models)
 * - only required models set -> keep the session on an account that has them
 * - neither -> default renewal
 */
export async function runKeeper(options = {}) {
  const env = options.env || process.env;
  const accountsPath = options.accountsPath || resolveAccountsPath(env);
  const authPath = options.authPath || resolveAuthPath(env);
  const logPath = options.logPath || resolveLogPath(env);
  const modelsUrl = options.modelsUrl || resolveModelsUrl(env);
  const requiredModels = options.requiredModels || parseRequiredModels(env.ANTIGRAVITY_REQUIRED_MODELS);
  const preferred = String(
    options.prefer ?? env.ANTIGRAVITY_PREFERRED_ACCOUNT ?? "",
  ).trim();

  if (preferred) {
    const result = await preferAccount({
      env,
      preferred,
      requiredModels,
      accountsPath,
      authPath,
      logPath,
      modelsUrl,
      oauthPath: options.oauthPath,
      fetchImpl: options.fetchImpl,
    });
    // Heal only once leadership is actually asserted. Before that decision the caller
    // promises the state is untouched, and rewriting the session credential would
    // make a failed prefer (missing account, missing model, catalog unavailable) move
    // the session anyway. Two files, no transaction: this converges a crashed
    // activation without ever contradicting a failed one. The renewal path never
    // heals, because there the plugin owns the credential and may have failed over
    // for quota without updating activeAccountId yet.
    if (result.exitCode === 0) selfHealCredential({ accountsPath, authPath, logPath });
    return result;
  }

  if (requiredModels.length > 0) {
    const result = await ensureCompatibleAccount({
      env,
      requiredModels,
      accountsPath,
      authPath,
      logPath,
      modelsUrl,
      oauthPath: options.oauthPath,
      fetchImpl: options.fetchImpl,
    });
    // Same convergence as the preferred branch, and for the same reason: this branch is
    // the one the session unit runs, so a crash between the store commit and the
    // credential mirror would otherwise leave Pi on the previous account while systemd
    // reported success. Only after success, so a failed run never moves the credential.
    if (result.exitCode === 0) selfHealCredential({ accountsPath, authPath, logPath });
    return result;
  }

  const renewal = await renewAccounts({ env, accountsPath, logPath, oauthPath: options.oauthPath });
  return { ...renewal, exitCode: renewal.failed > 0 || renewal.persistFailed ? 1 : 0 };
}

export function parseCliArgs(argv = []) {
  let prefer;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    let value;
    if (arg === "--prefer") {
      value = argv[i + 1];
      if (value === undefined || value.startsWith("-")) return { error: "--prefer requires a value" };
      i++;
    } else if (arg.startsWith("--prefer=")) {
      value = arg.slice("--prefer=".length);
    } else return { error: `unknown option: ${arg}` };
    // Both forms reject a blank value identically, before I/O.
    if (!value.trim()) return { error: "--prefer requires a non-empty value" };
    prefer = value.trim();
  }
  return { prefer };
}

const isMainModule =
  process.argv[1] &&
  (process.argv[1] === fileURLToPath(import.meta.url) ||
    fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)));

if (isMainModule) {
  const { prefer, error } = parseCliArgs(process.argv.slice(2));
  if (error) {
    process.stderr.write(`antigravity-account-keeper: ${error}\n`);
    process.exit(64);
  }
  runKeeper({ prefer })
    .then((result) => {
      process.exit(result.exitCode ?? 0);
    })
    .catch((err) => {
      process.stderr.write(`antigravity-account-keeper error: ${err.message}\n`);
      process.exit(1);
    });
}
