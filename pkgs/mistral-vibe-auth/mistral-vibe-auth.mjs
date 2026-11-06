#!/usr/bin/env node
// vibe-token — credential helper for Mistral's Vibe Code allowance.
//
// Mistral bills by credential kind, not by endpoint: an API key from Studio
// draws on the API allowance, while the browser sign-in the Vibe CLI uses
// yields an OIDC ID token that draws on the Vibe Code allowance, against the
// very same `https://api.mistral.ai/v1`. This helper performs that sign-in once,
// keeps the tokens in a 0600 file, refreshes them under a lock (the refresh
// token is single-use and rotates) and prints the bearer and tenant headers Pi
// needs at request time.
//
// Commands: login, token, header <name>, status, logout, help.

import { createHash, randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const DEFAULT_ISSUER = "https://auth.mistral.ai";
// Public client registered for Mistral's CLI (no client secret by design).
const DEFAULT_CLIENT_ID = "829da7e7-628f-4795-829a-8cca609c76d4";
const DEFAULT_AUDIENCE = "https://api.mistral.ai";
const SCOPE = "openid offline_access email profile";
const DEFAULT_REDIRECT_PORT = 8766;
const DEFAULT_API_BASE = "https://api.mistral.ai";
// Refresh this long before the bearer expires, so a request never carries a
// token that dies mid-flight.
const REFRESH_MARGIN_SECONDS = 120;
const LOGIN_TIMEOUT_SECONDS = 300;
const LOCK_TIMEOUT_MS = Number(env("VIBE_TOKEN_LOCK_TIMEOUT_MS", 20_000));
const UNATTRIBUTED_LOCK_GRACE_MS = 2_000;

const VERSION = "1.0.0";

function env(name, fallback) {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

const ISSUER = env("VIBE_TOKEN_ISSUER", DEFAULT_ISSUER).replace(/\/+$/, "");
const CLIENT_ID = env("VIBE_TOKEN_CLIENT_ID", DEFAULT_CLIENT_ID);
const AUDIENCE = env("VIBE_TOKEN_AUDIENCE", DEFAULT_AUDIENCE);
const API_BASE = env("VIBE_TOKEN_API_BASE", DEFAULT_API_BASE).replace(/\/+$/, "");
const REDIRECT_PORT = Number(env("VIBE_TOKEN_REDIRECT_PORT", DEFAULT_REDIRECT_PORT));
const STATE_DIR = env(
  "VIBE_TOKEN_DIR",
  path.join(env("XDG_CONFIG_HOME", path.join(os.homedir(), ".config")), "mistral-vibe"),
);
const STORE_PATH = path.join(STATE_DIR, "credentials.json");
const LOCK_PATH = path.join(STATE_DIR, "credentials.lock");
// Written by `logout`, so a sign-in that was already waiting for the browser
// cannot resurrect the session it interrupted.
const SIGNED_OUT_PATH = path.join(STATE_DIR, "signed-out.json");

class HelperError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

// ---------------------------------------------------------------- primitives

function base64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function decodeJwtClaims(token) {
  const parts = String(token ?? "").split(".");
  if (parts.length < 2) return null;
  try {
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

/** Absolute expiry (unix seconds) of the token we hand to the API. */
function bearerExpiry(store) {
  if (typeof store.id_token_expires_at === "number") return store.id_token_expires_at;
  const claims = decodeJwtClaims(store.id_token);
  if (claims && typeof claims.exp === "number") return claims.exp;
  if (typeof store.expires_at === "number") return store.expires_at;
  return 0;
}

function bearer(store) {
  const token = store.id_token || store.access_token;
  if (!token) throw new HelperError("stored credentials carry no token; run `vibe-token login`", 3);
  return token;
}

function isFresh(store, margin = REFRESH_MARGIN_SECONDS) {
  return bearerExpiry(store) - margin > Date.now() / 1000;
}

// ------------------------------------------------------------------- storage

function readStore() {
  let raw;
  try {
    raw = fs.readFileSync(STORE_PATH, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new HelperError(`cannot read ${STORE_PATH}: ${error.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch {
    throw new HelperError(`${STORE_PATH} is not valid JSON; run \`vibe-token login\``);
  }
}

function writeStore(store) {
  fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const temporary = `${STORE_PATH}.${process.pid}.tmp`;
  // Create with the final mode: never a window where the file is world-readable.
  const handle = fs.openSync(temporary, "w", 0o600);
  try {
    fs.writeSync(handle, `${JSON.stringify(store, null, 2)}\n`);
    fs.fsyncSync(handle);
  } finally {
    fs.closeSync(handle);
  }
  fs.renameSync(temporary, STORE_PATH);
  fs.chmodSync(STORE_PATH, 0o600);
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * Run `fn` while holding the store lock. The refresh token rotates on every
 * use, so two concurrent refreshes would burn each other's token: the lock is
 * the only thing standing between us and a broken sign-in.
 *
 * The lock file names its owner. A lock is reclaimed only when that owner is
 * gone, never merely because it looks old: a refresh may legitimately outlive
 * a timeout, and stealing its lock would hand a second process the same
 * single-use refresh token. Release is ownership-checked for the same reason.
 */
function withLock(fn) {
  fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const owner = `${process.pid}:${randomBytes(8).toString("hex")}`;
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  let held = false;
  while (!held) {
    try {
      acquireLockFile(owner);
      held = true;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (reclaimAbandonedLock()) continue;
      if (Date.now() > deadline) {
        throw new HelperError(`timed out waiting for ${LOCK_PATH}; another process is refreshing`);
      }
      sleepSync(100);
    }
  }
  const release = () => {
    // Only the lock this process still owns may be removed.
    try {
      if (fs.readFileSync(LOCK_PATH, "utf8").trim() === owner) fs.unlinkSync(LOCK_PATH);
    } catch {
      // Already reclaimed or removed: nothing of ours to release.
    }
  };
  return acquireResult(fn, release);
}

/**
 * Create the lock file with its owner already inside, in one atomic step.
 *
 * `open(O_CREAT|O_EXCL)` followed by a write leaves a window where the file
 * exists empty. A waiter that read it there would call it abandoned, unlink it
 * and enter the critical section alongside the owner, and two refreshes with
 * the same single-use token would burn one of them. Staging the content in a
 * sibling file and hard-linking it into place closes that window: the lock is
 * either absent or complete.
 */
function acquireLockFile(owner) {
  const staged = `${LOCK_PATH}.${process.pid}.staged`;
  fs.writeFileSync(staged, `${owner}\n`, { mode: 0o600 });
  try {
    // link(2) is atomic and refuses an existing destination with EEXIST.
    fs.linkSync(staged, LOCK_PATH);
  } finally {
    try {
      fs.unlinkSync(staged);
    } catch {
      // Best effort: a leftover staged file is inert.
    }
  }
}

/** Whether the process named by the lock file is still running. */
function lockHolderAlive() {
  let content;
  try {
    content = fs.readFileSync(LOCK_PATH, "utf8").trim();
  } catch {
    return false;
  }
  const pid = Number(content.split(":")[0]);
  if (!Number.isInteger(pid) || pid <= 0) {
    // Content we cannot attribute is not proof of a dead owner: only a foreign
    // or corrupt writer produces it. Give it a grace period instead of stealing
    // it, so a half-written lock can never be taken over immediately.
    try {
      return Date.now() - fs.statSync(LOCK_PATH).mtimeMs < UNATTRIBUTED_LOCK_GRACE_MS;
    } catch {
      return false;
    }
  }
  if (pid === process.pid) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means it exists and belongs to someone else.
    return error.code === "EPERM";
  }
}

/** Removes a lock whose owner is gone, unless something changed under us. */
function reclaimAbandonedLock() {
  if (lockHolderAlive()) return false;
  let content;
  try {
    content = fs.readFileSync(LOCK_PATH, "utf8");
  } catch {
    return true;
  }
  try {
    if (fs.readFileSync(LOCK_PATH, "utf8") !== content) return false;
    fs.unlinkSync(LOCK_PATH);
  } catch {
    // Another waiter reclaimed it first.
  }
  return true;
}

async function acquireResult(fn, release) {
  try {
    // Await the body: releasing on a returned promise would let a second
    // process refresh with the token we are about to burn.
    return await fn();
  } finally {
    release();
  }
}

/** When `logout` last ran, or null when it never did. */
function readSignedOutAt() {
  try {
    const parsed = JSON.parse(fs.readFileSync(SIGNED_OUT_PATH, "utf8"));
    return typeof parsed.at === "number" ? parsed.at : 0;
  } catch {
    return null;
  }
}

/** Read-modify-write of the store, serialized against every other writer. */
function updateStore(mutate) {
  return withLock(() => {
    const latest = readStore();
    const next = mutate(latest);
    if (next) writeStore(next);
    return next;
  });
}

// ------------------------------------------------------------------- network

async function fetchJson(url, init, what) {
  let response;
  try {
    response = await fetch(url, init);
  } catch (error) {
    const cause = error.cause?.code || error.message;
    throw new HelperError(`${what} failed: ${cause}`);
  }
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { raw: text.slice(0, 500) };
  }
  return { response, body };
}

async function discoverMetadata() {
  const url = `${ISSUER}/.well-known/openid-configuration`;
  const { response, body } = await fetchJson(url, { headers: { accept: "application/json" } }, "OIDC discovery");
  if (!response.ok) {
    throw new HelperError(`OIDC discovery returned HTTP ${response.status} for ${url}`);
  }
  if (!body.authorization_endpoint || !body.token_endpoint) {
    throw new HelperError(`OIDC discovery at ${url} lacks authorization/token endpoints`);
  }
  return body;
}

async function exchangeCode({ metadata, code, verifier, port }) {
  const form = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    // The token endpoint rejects a redirect_uri that differs in any way from
    // the one the authorization request carried, port included.
    redirect_uri: redirectUri(port),
    client_id: CLIENT_ID,
    code_verifier: verifier,
  });
  const { response, body } = await fetchJson(
    metadata.token_endpoint,
    {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: form.toString(),
    },
    "token exchange",
  );
  if (!response.ok) {
    throw new HelperError(
      `token exchange rejected with HTTP ${response.status}: ${body.error_description || body.error || "no detail"}`,
    );
  }
  return body;
}

async function refreshTokens(metadata, store) {
  const form = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: store.refresh_token,
    client_id: CLIENT_ID,
  });
  const { response, body } = await fetchJson(
    metadata.token_endpoint,
    {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: form.toString(),
    },
    "token refresh",
  );
  if (!response.ok) {
    const detail = body.error_description || body.error || "no detail";
    if (body.error === "invalid_grant" || response.status === 400 || response.status === 401) {
      throw new HelperError(
        `sign-in can no longer be refreshed (${detail}); run \`vibe-token login\` again`,
        3,
      );
    }
    throw new HelperError(`token refresh returned HTTP ${response.status}: ${detail}`);
  }
  return body;
}

async function discoverTenant(store) {
  const token = bearer(store);
  const { response, body } = await fetchJson(
    `${API_BASE}/v1/users/me/workspaces?limit=100`,
    { headers: { authorization: `Bearer ${token}`, accept: "application/json" } },
    "workspace discovery",
  );
  if (!response.ok) {
    throw new HelperError(`workspace discovery returned HTTP ${response.status}`, 4);
  }
  const workspace = (body.workspaces || [])[0];
  if (!workspace || !workspace.organization_id) {
    throw new HelperError("no workspace found for this account; ask an admin for access", 4);
  }
  return {
    organization_id: workspace.organization_id,
    workspace_id: workspace.id || null,
  };
}

// -------------------------------------------------------------------- tokens

async function currentStore({ refresh = true } = {}) {
  const store = readStore();
  if (!store) throw new HelperError("not signed in; run `vibe-token login`", 3);
  if (!refresh || isFresh(store)) return store;
  return withLock(async () => {
    // Another process may have refreshed while we waited for the lock.
    const latest = readStore();
    if (!latest) throw new HelperError("credentials disappeared; run `vibe-token login`", 3);
    if (isFresh(latest)) return latest;
    if (!latest.refresh_token) {
      throw new HelperError("stored credentials carry no refresh token; run `vibe-token login`", 3);
    }
    const metadata = await discoverMetadata();
    const tokens = await refreshTokens(metadata, latest);
    if (!tokens.id_token) {
      // The bearer is the ID token, so this shape cannot extend the sign-in.
      // Fail before persisting: the rotated refresh token is not worth keeping.
      throw new HelperError(
        "the issuer returned no fresh ID token, so the sign-in cannot be extended; run `vibe-token login`",
        3,
      );
    }
    const updated = mergeTokens(latest, tokens);
    writeStore(updated);
    return updated;
  });
}

function mergeTokens(previous, tokens) {
  const idToken = tokens.id_token || previous.id_token;
  const claims = decodeJwtClaims(idToken);
  const now = Date.now() / 1000;
  return {
    version: 1,
    issuer: ISSUER,
    client_id: CLIENT_ID,
    audience: AUDIENCE,
    subject: claims?.sub || previous.subject || null,
    access_token: tokens.access_token || previous.access_token,
    refresh_token: tokens.refresh_token || previous.refresh_token,
    id_token: idToken,
    expires_at: now + Number(tokens.expires_in || 0),
    id_token_expires_at: tokens.id_token
      ? Number(claims?.exp ?? 0) || previous.id_token_expires_at || null
      : previous.id_token_expires_at,
    tenant: previous.tenant || null,
    obtained_at: now,
  };
}

// --------------------------------------------------------------------- login

function redirectUri(port = REDIRECT_PORT) {
  return `http://127.0.0.1:${port}/callback`;
}

function openBrowser(url) {
  try {
    const child = spawn("xdg-open", [url], { detached: true, stdio: "ignore" });
    child.on("error", () => {});
    child.unref();
    return true;
  } catch {
    return false;
  }
}

/** Strict parser: an ignored option has already cost us a secret once. */
function parseLoginArgs(argv) {
  let noBrowser = false;
  let port = REDIRECT_PORT;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--no-browser") {
      noBrowser = true;
    } else if (arg === "--port" || arg.startsWith("--port=")) {
      const raw = arg === "--port" ? argv[(index += 1)] : arg.slice("--port=".length);
      if (raw === undefined) throw new HelperError("--port needs a port number", 2);
      port = Number(raw);
    } else if (arg === "--help" || arg === "-h") {
      return null;
    } else {
      throw new HelperError(`\`login\` does not accept "${arg}"; run \`vibe-token help\``, 2);
    }
  }
  if (!Number.isInteger(port) || port <= 0) throw new HelperError("--port needs a port number", 2);
  return { noBrowser, port };
}

async function commandLogin(argv) {
  const startedAt = Date.now();
  const options = parseLoginArgs(argv);
  if (!options) {
    process.stdout.write(usage());
    return;
  }
  const { noBrowser, port } = options;

  const metadata = await discoverMetadata();
  const verifier = base64url(randomBytes(64));
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const state = base64url(randomBytes(32));
  const nonce = base64url(randomBytes(32));

  const authorizeUrl = new URL(metadata.authorization_endpoint);
  authorizeUrl.searchParams.set("response_type", "code");
  authorizeUrl.searchParams.set("client_id", CLIENT_ID);
  authorizeUrl.searchParams.set("redirect_uri", redirectUri(port));
  authorizeUrl.searchParams.set("scope", SCOPE);
  authorizeUrl.searchParams.set("state", state);
  authorizeUrl.searchParams.set("nonce", nonce);
  authorizeUrl.searchParams.set("code_challenge", challenge);
  authorizeUrl.searchParams.set("code_challenge_method", "S256");
  if (AUDIENCE) authorizeUrl.searchParams.set("audience", AUDIENCE);

  const code = await waitForCallback({ port, state, url: authorizeUrl.toString(), noBrowser });
  const tokens = await exchangeCode({ metadata, code, verifier, port });
  const store = mergeTokens(
    { version: 1 },
    { ...tokens, id_token: tokens.id_token || null },
  );
  store.subject = decodeJwtClaims(store.id_token)?.sub || null;
  const signedIn = await updateStore(() => {
    // The marker is a durable watermark, not a one-shot flag: clearing it would
    // let a login that started before the sign-out overwrite a later one.
    const signedOutAt = readSignedOutAt();
    if (signedOutAt !== null && signedOutAt > startedAt) return null;
    return store;
  });
  if (!signedIn) {
    throw new HelperError("a sign-out happened while you were signing in; run `vibe-token login` again", 3);
  }

  let tenant = null;
  try {
    tenant = await discoverTenant(store);
  } catch (error) {
    // Discovery is best effort: the sign-in itself still succeeded.
    process.stderr.write(`warning: ${error.message}\n`);
  }
  if (tenant) {
    // A sign-out that landed while we discovered must not be resurrected, and
    // must not be reported as a successful sign-in either.
    const written = await updateStore((latest) => (latest ? { ...latest, tenant } : null));
    if (!written) {
      throw new HelperError("a sign-out happened while you were signing in; run `vibe-token login` again", 3);
    }
    // The status printed below reads this object, not the store on disk.
    store.tenant = tenant;
    process.stderr.write(`Workspace: ${tenant.workspace_id} (organization ${tenant.organization_id})\n`);
  }
  process.stderr.write("Signed in.\n");
  process.stdout.write(`${JSON.stringify(publicStatus(store), null, 2)}\n`);
}

function waitForCallback({ port, state, url, noBrowser }) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((request, response) => {
      const incoming = new URL(request.url, `http://127.0.0.1:${port}`);
      if (incoming.pathname !== "/callback") {
        response.writeHead(404).end("Not found");
        return;
      }
      const receive = incoming.searchParams;
      const reply = (status, message) => {
        response.writeHead(status, { "content-type": "text/plain; charset=utf-8" }).end(message);
      };
      if (receive.get("error")) {
        reply(400, `Sign-in failed: ${receive.get("error")}`);
        finish(new HelperError(`sign-in failed: ${receive.get("error_description") || receive.get("error")}`));
        return;
      }
      if (receive.get("state") !== state) {
        reply(400, "State mismatch. Start again with `vibe-token login`.");
        finish(new HelperError("callback state did not match; refusing the code"));
        return;
      }
      const code = receive.get("code");
      if (!code) {
        reply(400, "No authorization code in callback.");
        finish(new HelperError("callback carried no authorization code"));
        return;
      }
      reply(200, "Signed in. You can close this tab.");
      finish(null, code);
    });

    const timer = setTimeout(() => {
      finish(new HelperError(`no sign-in after ${LOGIN_TIMEOUT_SECONDS}s; run \`vibe-token login\` again`));
    }, LOGIN_TIMEOUT_SECONDS * 1000);

    let settled = false;
    function finish(error, code) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      server.close(() => (error ? reject(error) : resolve(code)));
    }

    server.on("error", (error) => {
      if (error.code === "EADDRINUSE") {
        finish(new HelperError(`127.0.0.1:${port} is busy; pass --port <other>`));
        return;
      }
      finish(new HelperError(`callback server failed: ${error.message}`));
    });

    server.listen(port, "127.0.0.1", () => {
      const opened = noBrowser ? false : openBrowser(url);
      process.stderr.write(
        `${opened ? "Opening your browser" : "Open this URL in your browser"}:\n\n  ${url}\n\n` +
          `Waiting for the sign-in to come back to http://127.0.0.1:${port}/callback ...\n`,
      );
    });
  });
}

// ------------------------------------------------------------------ commands

function publicStatus(store) {
  const expiry = bearerExpiry(store);
  const secondsLeft = Math.round(expiry - Date.now() / 1000);
  return {
    signedIn: true,
    issuer: store.issuer ?? ISSUER,
    audience: store.audience ?? AUDIENCE,
    subject: store.subject ?? null,
    bearerExpiresInSeconds: secondsLeft,
    tenant: store.tenant
      ? { organizationId: store.tenant.organization_id, workspaceId: store.tenant.workspace_id }
      : null,
  };
}

async function commandToken() {
  const store = await currentStore();
  if (!isFresh(store)) {
    throw new HelperError("bearer is still expired after a refresh attempt; run `vibe-token login`", 3);
  }
  process.stdout.write(`${bearer(store)}\n`);
}

async function commandHeader(name) {
  if (name !== "organization" && name !== "workspace") {
    throw new HelperError(`\`header\` accepts only organization|workspace, not "${name}"`, 2);
  }
  const normalized = String(name || "").toLowerCase();
  const field = normalized.includes("workspace") ? "workspace_id" : "organization_id";
  let store = readStore();
  if (!store) throw new HelperError("not signed in; run `vibe-token login`", 3);
  if (!store.tenant) {
    store = await currentStore();
    const tenant = await discoverTenant(store);
    const written = await updateStore((latest) => (latest ? { ...latest, tenant } : null));
    if (!written) throw new HelperError("signed out while resolving the workspace", 3);
    store = written;
  }
  const value = store.tenant[field];
  if (!value) throw new HelperError(`no ${field} stored; run \`vibe-token login\``, 4);
  process.stdout.write(`${value}\n`);
}

async function commandStatus() {
  const store = readStore();
  if (!store) {
    process.stdout.write(`${JSON.stringify({ signedIn: false }, null, 2)}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify(publicStatus(store), null, 2)}\n`);
}

async function commandLogout() {
  // Serialized with refresh: otherwise a refresh in flight would rewrite the
  // store right after "Signed out." and leave the user authenticated. The
  // marker records the sign-out for a sign-in that is still waiting for the
  // browser, which no lock can order against.
  const removed = await withLock(() => {
    fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    fs.writeFileSync(SIGNED_OUT_PATH, `${JSON.stringify({ at: Date.now() })}\n`, { mode: 0o600 });
    try {
      fs.unlinkSync(STORE_PATH);
      return true;
    } catch (error) {
      if (error.code === "ENOENT") return false;
      throw new HelperError(`cannot remove ${STORE_PATH}: ${error.message}`);
    }
  });
  process.stdout.write(removed ? "Signed out.\n" : "Already signed out.\n");
}

/** Refuse arguments a command does not accept: an ignored flag can destroy state. */
function requireNoArgs(rest, command) {
  if (rest.length === 0) return;
  throw new HelperError(
    `\`${command}\` takes no arguments (got ${rest.map((arg) => `"${arg}"`).join(" ")}); run \`vibe-token help\``,
    2,
  );
}

function usage() {
  return `vibe-token — Mistral Vibe Code credentials for Pi

Usage:
  vibe-token login [--no-browser] [--port N]  Browser sign-in (OIDC + PKCE); stores tokens in ${STORE_PATH}
  vibe-token token                            Print the bearer for the Vibe allowance, refreshing if needed
  vibe-token header organization|workspace    Print a tenant header value
  vibe-token status                           Show sign-in state without secrets
  vibe-token logout                           Remove the stored tokens
  vibe-token help                             This text

Environment: VIBE_TOKEN_DIR, VIBE_TOKEN_ISSUER, VIBE_TOKEN_CLIENT_ID, VIBE_TOKEN_AUDIENCE,
             VIBE_TOKEN_API_BASE, VIBE_TOKEN_REDIRECT_PORT (for tests and unusual setups).
`;
}

async function main(argv) {
  const [command, ...rest] = argv;
  switch (command) {
    case "login":
      return commandLogin(rest);
    case "token":
      requireNoArgs(rest, "token");
      return commandToken();
    case "header": {
      if (rest.length !== 1) {
        throw new HelperError(
          `\`header\` needs exactly one of organization|workspace; run \`vibe-token help\``,
          2,
        );
      }
      return commandHeader(rest[0]);
    }
    case "status":
      requireNoArgs(rest, "status");
      return commandStatus();
    case "logout":
      requireNoArgs(rest, "logout");
      return commandLogout();
    case "--version":
      process.stdout.write(`vibe-token ${VERSION}\n`);
      return;
    case "help":
    case "--help":
    case "-h":
    case undefined:
      process.stdout.write(usage());
      return;
    default:
      throw new HelperError(`unknown command "${command}"\n\n${usage()}`, 2);
  }
}

main(process.argv.slice(2)).catch((error) => {
  const message = error instanceof HelperError ? error.message : `unexpected failure: ${error.stack || error}`;
  process.stderr.write(`vibe-token: ${message}\n`);
  process.exit(error instanceof HelperError ? error.exitCode : 1);
});
