#!/usr/bin/env node

/**
 * Tests for Antigravity Account Keeper
 *
 * Verifies without real network access and without touching user state:
 * (a) Account due to expire is renewed and persisted
 * (b) Fresh account is not touched
 * (c) HTTP failure does not overwrite and returns exit != 0
 * (d) activeAccountId never changes in the default renewal mode
 * (e) --prefer activates the preferred account and mirrors auth.json, preserving
 *     every other key
 * (f) --prefer changes nothing and exits 2 when the preferred account lacks a
 *     required model
 * (g) effort-suffixed model ids satisfy their base id
 * (h) active-account model verification exits 2 when a required model is missing
 * (i) an unavailable catalog never fails the session
 * (j) no output or log line ever contains a token
 */

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { ensureCompatibleAccount, extractModelIds, findMissingModels, resolveOAuthConstants, withStoreRetry } from "./keeper.mjs";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const keeperScript = path.join(__dirname, "keeper.mjs");

const EXPECTED_USER_AGENT =
  "antigravity/cli/1.4.0 (aidev_client; os_type=linux; arch=amd64; cl=982146307; auth_method=consumer)";

function createMockServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => {
        body += chunk;
      });
      req.on("end", () => {
        handler(req, body, res);
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      const base = `http://127.0.0.1:${port}`;
      resolve({
        base,
        url: `${base}/token`,
        close: () =>
          new Promise((done) => {
            server.closeAllConnections?.();
            server.close(done);
          }),
      });
    });
  });
}

function runKeeper(env, args = []) {
  return new Promise((resolve) => {
    execFile(
      process.execPath,
      [keeperScript, ...args],
      { env, encoding: "utf8" },
      (err, stdout, stderr) => {
        resolve({
          status: err ? (typeof err.code === "number" ? err.code : 1) : 0,
          stdout,
          stderr,
        });
      },
    );
  });
}

function modelsPayload(ids) {
  return JSON.stringify({
    models: Object.fromEntries(ids.map((id) => [id, { id, label: id, model: `MODEL_${id}` }])),
  });
}

function assertNoSecrets(text, secrets) {
  for (const secret of secrets) {
    assert.ok(
      !String(text).includes(secret),
      `secret "${secret}" must never appear in output or logs`,
    );
  }
}

function makeTempAgentDir(prefix) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const agentDir = path.join(tempDir, ".pi", "agent");
  fs.mkdirSync(agentDir, { recursive: true });
  return tempDir;
}

/** Temp agent dir with a two-account store (active `other`, preferred `preferred`). */
function scenario(prefix, preferredMs = 50 * 60 * 1000) {
  const tempDir = makeTempAgentDir(prefix);
  const now = Date.now();
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const authFile = path.join(tempDir, "auth.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");
  const entry = (email, expires, projectId) => ({
    accountId: email, email, access: `${email}/access`, refresh: `${email}/refresh`, expires, projectId,
  });
  fs.writeFileSync(accountsFile, JSON.stringify({
    version: 1,
    activeAccountId: "other@example.com",
    accounts: {
      "other@example.com": entry("other@example.com", now + 50 * 60 * 1000, "project-other"),
      "preferred@example.com": entry("preferred@example.com", now + preferredMs, "project-pref"),
    },
  }, null, 2), { mode: 0o600 });
  return {
    accountsFile, authFile, logFile,
    cleanup: () => fs.rmSync(tempDir, { recursive: true, force: true }),
    env: {
      ...process.env,
      HOME: tempDir, PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile, ANTIGRAVITY_AUTH_FILE: authFile,
      ANTIGRAVITY_LOG_FILE: logFile, ANTIGRAVITY_CLIENT_ID: "id", ANTIGRAVITY_CLIENT_SECRET: "secret",
      ANTIGRAVITY_PREFERRED_ACCOUNT: "", ANTIGRAVITY_REQUIRED_MODELS: "",
    },
  };
}

test("renews expiring account, preserves fresh account, keeps activeAccountId and permissions", async () => {
  const requests = [];
  const server = await createMockServer((req, body, res) => {
    const params = new URLSearchParams(body);
    requests.push({
      method: req.method,
      grantType: params.get("grant_type"),
      clientId: params.get("client_id"),
      clientSecret: params.get("client_secret"),
      refreshToken: params.get("refresh_token"),
    });

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        access_token: "new-access-token-12345",
        expires_in: 3600,
        refresh_token: "rotated-refresh-token-67890",
      }),
    );
  });

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "keeper-test-"));
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  try {
    const now = Date.now();
    const initialStore = {
      version: 1,
      activeAccountId: "fresh-account@example.com",
      accounts: {
        "expiring-account@example.com": {
          accountId: "expiring-account@example.com",
          email: "expiring-account@example.com",
          access: "old-expiring-access-token",
          refresh: "refresh-token-alpha",
          expires: now + 3 * 60 * 1000, // 3 minutes left: within 10 min window
          projectId: "project-alpha",
          addedAt: 100000,
          lastUsedAt: 200000,
        },
        "fresh-account@example.com": {
          accountId: "fresh-account@example.com",
          email: "fresh-account@example.com",
          access: "untouched-fresh-access-token",
          refresh: "refresh-token-beta",
          expires: now + 50 * 60 * 1000, // 50 minutes left: fresh
          projectId: "project-beta",
          addedAt: 300000,
          lastUsedAt: 400000,
        },
      },
    };

    fs.writeFileSync(accountsFile, JSON.stringify(initialStore, null, 2), { mode: 0o600 });

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_TOKEN_URL: server.url,
      ANTIGRAVITY_CLIENT_ID: "mock-client-id",
      ANTIGRAVITY_CLIENT_SECRET: "mock-client-secret",
    });

    assert.equal(proc.status, 0, `Process failed with stderr: ${proc.stderr}`);

    // Exactly one renewal request sent (for expiring account)
    assert.equal(requests.length, 1);
    assert.equal(requests[0].grantType, "refresh_token");
    assert.equal(requests[0].refreshToken, "refresh-token-alpha");
    assert.equal(requests[0].clientId, "mock-client-id");
    assert.equal(requests[0].clientSecret, "mock-client-secret");

    const updatedStore = JSON.parse(fs.readFileSync(accountsFile, "utf8"));

    // (d) activeAccountId is untouched
    assert.equal(updatedStore.activeAccountId, "fresh-account@example.com");
    assert.equal(updatedStore.version, 1);

    // (a) expiring account renewed and persisted, with rotated refresh token saved
    const renewed = updatedStore.accounts["expiring-account@example.com"];
    assert.equal(renewed.access, "new-access-token-12345");
    assert.equal(renewed.refresh, "rotated-refresh-token-67890");
    assert.ok(renewed.expires > now + 30 * 60 * 1000);
    assert.equal(renewed.projectId, "project-alpha");
    assert.equal(renewed.addedAt, 100000);
    assert.equal(renewed.lastUsedAt, 200000);
    assert.equal(renewed.email, "expiring-account@example.com");
    assert.equal(renewed.accountId, "expiring-account@example.com");

    // (b) fresh account untouched
    const fresh = updatedStore.accounts["fresh-account@example.com"];
    assert.equal(fresh.access, "untouched-fresh-access-token");
    assert.equal(fresh.refresh, "refresh-token-beta");
    assert.equal(fresh.expires, initialStore.accounts["fresh-account@example.com"].expires);
    assert.equal(fresh.projectId, "project-beta");
    assert.equal(fresh.addedAt, 300000);
    assert.equal(fresh.lastUsedAt, 400000);

    // File mode 0600 check
    const stat = fs.statSync(accountsFile);
    assert.equal(stat.mode & 0o777, 0o600);

    // Log file check: 0600 mode, contains email, ok, minutes, no tokens
    assert.ok(fs.existsSync(logFile));
    const logStat = fs.statSync(logFile);
    assert.equal(logStat.mode & 0o777, 0o600);
    const logContent = fs.readFileSync(logFile, "utf8");
    assert.match(logContent, /email=expiring-account@example\.com result=ok minutes_until_expiry=3/);
    assert.doesNotMatch(logContent, /new-access-token/);
    assert.doesNotMatch(logContent, /rotated-refresh-token/);
    assert.doesNotMatch(logContent, /mock-client-secret/);
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("idempotent when no accounts need renewal", async () => {
  let requestsCount = 0;
  const server = await createMockServer((_req, _body, res) => {
    requestsCount++;
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ access_token: "new", expires_in: 3600 }));
  });

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "keeper-test-"));
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  try {
    const store = {
      version: 1,
      activeAccountId: "fresh@example.com",
      accounts: {
        "fresh@example.com": {
          accountId: "fresh@example.com",
          email: "fresh@example.com",
          access: "fresh-access",
          refresh: "fresh-refresh",
          expires: Date.now() + 45 * 60 * 1000,
        },
      },
    };
    fs.writeFileSync(accountsFile, JSON.stringify(store, null, 2), { mode: 0o600 });
    const mtimeBefore = fs.statSync(accountsFile).mtimeMs;

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_TOKEN_URL: server.url,
      ANTIGRAVITY_CLIENT_ID: "mock-client-id",
      ANTIGRAVITY_CLIENT_SECRET: "mock-client-secret",
    });

    assert.equal(proc.status, 0);
    assert.equal(requestsCount, 0, "No network request should be sent when accounts are fresh");

    const mtimeAfter = fs.statSync(accountsFile).mtimeMs;
    assert.equal(mtimeAfter, mtimeBefore, "File must not be touched when nothing is expiring");
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("HTTP failure does not overwrite account and returns exit != 0", async () => {
  const server = await createMockServer((_req, _body, res) => {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "invalid_grant", error_description: "Token revoked" }));
  });

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "keeper-test-"));
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  try {
    const now = Date.now();
    const initialStore = {
      version: 1,
      activeAccountId: "someone-else@example.com",
      accounts: {
        "failing@example.com": {
          accountId: "failing@example.com",
          email: "failing@example.com",
          access: "initial-unmodified-access",
          refresh: "revoked-refresh-token",
          expires: now + 2 * 60 * 1000, // Expiring in 2m
          projectId: "proj-fail",
        },
      },
    };
    fs.writeFileSync(accountsFile, JSON.stringify(initialStore, null, 2), { mode: 0o600 });
    const contentBefore = fs.readFileSync(accountsFile, "utf8");

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_TOKEN_URL: server.url,
      ANTIGRAVITY_CLIENT_ID: "mock-client-id",
      ANTIGRAVITY_CLIENT_SECRET: "mock-client-secret",
    });

    // (c) Script returns non-zero exit code
    assert.notEqual(proc.status, 0);

    // Accounts file is NOT overwritten
    const contentAfter = fs.readFileSync(accountsFile, "utf8");
    assert.equal(contentAfter, contentBefore);

    // Log file records failed status, without leaking secrets
    const logContent = fs.readFileSync(logFile, "utf8");
    assert.match(logContent, /email=failing@example\.com result=failed minutes_until_expiry=2/);
    assert.doesNotMatch(logContent, /revoked-refresh-token/);
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("resolves constants from oauth.ts file when env vars are omitted", async () => {
  let receivedClientId = null;
  let receivedClientSecret = null;

  const server = await createMockServer((_req, body, res) => {
    const params = new URLSearchParams(body);
    receivedClientId = params.get("client_id");
    receivedClientSecret = params.get("client_secret");

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ access_token: "renewed-access", expires_in: 3600 }));
  });

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "keeper-test-"));
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");
  const mockOAuthFile = path.join(tempDir, "oauth.ts");

  try {
    const fullClientIdB64 = Buffer.from("extracted-client-id-part1-part2").toString("base64");
    const p1 = fullClientIdB64.slice(0, 16);
    const p2 = fullClientIdB64.slice(16);
    const secretB64 = Buffer.from("extracted-secret-value").toString("base64");

    const mockOAuthContent = `
export const TOKEN_URL = "${server.url}";
export const CLIENT_ID =
  antigravityEnv("CLIENT_ID") ||
  atob("${p1}" + "${p2}");
export const CLIENT_SECRET =
  antigravityEnv("CLIENT_SECRET") || atob("${secretB64}");
`;
    fs.writeFileSync(mockOAuthFile, mockOAuthContent, "utf8");

    const store = {
      version: 1,
      activeAccountId: "nobody@example.com",
      accounts: {
        "test@example.com": {
          accountId: "test@example.com",
          email: "test@example.com",
          access: "old-access",
          refresh: "refresh-val",
          expires: Date.now() + 1000, // expiring right now
        },
      },
    };
    fs.writeFileSync(accountsFile, JSON.stringify(store, null, 2), { mode: 0o600 });

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_OAUTH_PATH: mockOAuthFile,
      // Clear overrides to force resolution from mockOAuthFile
      ANTIGRAVITY_TOKEN_URL: "",
      ANTIGRAVITY_CLIENT_ID: "",
      ANTIGRAVITY_CLIENT_SECRET: "",
      TOKEN_URL: "",
      CLIENT_ID: "",
      CLIENT_SECRET: "",
    });

    assert.equal(proc.status, 0, `stderr: ${proc.stderr}`);
    assert.equal(receivedClientId, "extracted-client-id-part1-part2");
    assert.equal(receivedClientSecret, "extracted-secret-value");
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("skips the active account: pi-antigravity owns its refresh", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "antigravity-keeper-active-"));
  const agentDir = path.join(tempDir, ".pi", "agent");
  fs.mkdirSync(agentDir, { recursive: true });
  const accountsFile = path.join(agentDir, "antigravity-accounts.json");

  let requests = 0;
  const server = await createMockServer((_req, _body, res) => {
    requests++;
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ access_token: "should-not-be-used", expires_in: 3600 }));
  });

  try {
    const store = {
      version: 1,
      activeAccountId: "active@example.com",
      accounts: {
        "active@example.com": {
          accountId: "active@example.com",
          email: "active@example.com",
          access: "active-old-access",
          refresh: "active-refresh",
          expires: Date.now() + 60 * 1000,
        },
      },
    };
    fs.writeFileSync(accountsFile, JSON.stringify(store, null, 2), { mode: 0o600 });
    const before = fs.readFileSync(accountsFile, "utf8");

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      ANTIGRAVITY_TOKEN_URL: server.url,
      ANTIGRAVITY_CLIENT_ID: "id",
      ANTIGRAVITY_CLIENT_SECRET: "secret",
    });

    assert.equal(proc.status, 0, `stderr: ${proc.stderr}`);
    assert.equal(requests, 0, "the active account must not be refreshed by the keeper");
    assert.equal(fs.readFileSync(accountsFile, "utf8"), before, "the store must stay untouched");
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("(e) prefer activates the preferred account, refreshes its token and preserves the rest of auth.json", async () => {
  const tokenRequests = [];
  const modelRequests = [];
  const server = await createMockServer((req, body, res) => {
    if (req.url.startsWith("/token")) {
      const params = new URLSearchParams(body);
      tokenRequests.push({
        refreshToken: params.get("refresh_token"),
        clientId: params.get("client_id"),
        clientSecret: params.get("client_secret"),
      });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          access_token: "preferred-new-access-SECRET",
          refresh_token: "preferred-new-refresh-SECRET",
          expires_in: 3600,
        }),
      );
      return;
    }
    modelRequests.push({
      method: req.method,
      userAgent: req.headers["user-agent"],
      authorization: req.headers.authorization,
      body: JSON.parse(body || "{}"),
    });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(modelsPayload(["claude-opus-5-5-high", "claude-sonnet-5-5-medium"]));
  });

  const tempDir = makeTempAgentDir("keeper-prefer-");
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const authFile = path.join(tempDir, "auth.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  const secrets = [
    "preferred-old-access-SECRET",
    "preferred-refresh-SECRET",
    "preferred-new-access-SECRET",
    "preferred-new-refresh-SECRET",
    "other-access-SECRET",
    "mock-client-secret",
  ];

  try {
    const now = Date.now();
    fs.writeFileSync(
      accountsFile,
      JSON.stringify(
        {
          version: 1,
          activeAccountId: "other@example.com",
          accounts: {
            "other@example.com": {
              accountId: "other@example.com",
              email: "other@example.com",
              access: "other-access-SECRET",
              refresh: "other-refresh-SECRET",
              expires: now + 50 * 60 * 1000,
              projectId: "project-other",
              lastUsedAt: 111,
            },
            "preferred@example.com": {
              accountId: "preferred@example.com",
              email: "preferred@example.com",
              access: "preferred-old-access-SECRET",
              refresh: "preferred-refresh-SECRET",
              expires: now + 60 * 1000, // stale: must refresh before activation
              projectId: "project-pref",
              addedAt: 222,
            },
          },
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );

    const initialAuth = {
      openai: { type: "api_key", key: "keep-me-untouched" },
      antigravity: {
        type: "oauth",
        email: "other@example.com",
        access: "other-access-SECRET",
        refresh: "other-refresh-SECRET",
        expires: now + 50 * 60 * 1000,
        projectId: "project-other",
      },
    };
    fs.writeFileSync(authFile, JSON.stringify(initialAuth, null, 2), { mode: 0o600 });

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_AUTH_FILE: authFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_TOKEN_URL: server.url,
      ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
      ANTIGRAVITY_CLIENT_ID: "mock-client-id",
      ANTIGRAVITY_CLIENT_SECRET: "mock-client-secret",
      ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com",
      ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5,claude-sonnet-5-5",
    });

    assert.equal(proc.status, 0, `stderr: ${proc.stderr}`);

    // The stale preferred token was refreshed with its own refresh token.
    assert.equal(tokenRequests.length, 1);
    assert.equal(tokenRequests[0].refreshToken, "preferred-refresh-SECRET");
    assert.equal(tokenRequests[0].clientId, "mock-client-id");
    assert.equal(tokenRequests[0].clientSecret, "mock-client-secret");

    // The catalog was queried with the CLI fingerprint and the fresh token.
    assert.equal(modelRequests.length, 1);
    assert.equal(modelRequests[0].method, "POST");
    assert.equal(modelRequests[0].userAgent, EXPECTED_USER_AGENT);
    assert.equal(modelRequests[0].authorization, "Bearer preferred-new-access-SECRET");
    assert.deepEqual(modelRequests[0].body, { project: "project-pref" });

    const updatedStore = JSON.parse(fs.readFileSync(accountsFile, "utf8"));
    assert.equal(updatedStore.activeAccountId, "preferred@example.com");

    const activated = updatedStore.accounts["preferred@example.com"];
    assert.equal(activated.access, "preferred-new-access-SECRET");
    assert.equal(activated.refresh, "preferred-new-refresh-SECRET");
    assert.ok(activated.expires > now + 30 * 60 * 1000);
    assert.equal(activated.projectId, "project-pref");
    assert.equal(activated.email, "preferred@example.com");
    assert.ok(activated.lastUsedAt >= now);

    // The previously active account is untouched.
    const other = updatedStore.accounts["other@example.com"];
    assert.equal(other.access, "other-access-SECRET");
    assert.equal(other.refresh, "other-refresh-SECRET");
    assert.equal(other.expires, now + 50 * 60 * 1000);
    assert.equal(other.lastUsedAt, 111);

    // auth.json: antigravity replaced, every other key preserved byte-for-byte.
    const updatedAuth = JSON.parse(fs.readFileSync(authFile, "utf8"));
    assert.deepEqual(updatedAuth.openai, { type: "api_key", key: "keep-me-untouched" });
    assert.deepEqual(updatedAuth.antigravity, {
      type: "oauth",
      email: "preferred@example.com",
      access: "preferred-new-access-SECRET",
      refresh: "preferred-new-refresh-SECRET",
      expires: activated.expires,
      projectId: "project-pref",
    });

    assert.equal(fs.statSync(accountsFile).mode & 0o777, 0o600);
    assert.equal(fs.statSync(authFile).mode & 0o777, 0o600);

    const logContent = fs.readFileSync(logFile, "utf8");
    assert.match(logContent, /email=preferred@example\.com result=activated/);
    assert.equal(fs.statSync(logFile).mode & 0o777, 0o600);

    // (j) no captured stream or log line leaks a token.
    assertNoSecrets(proc.stdout, secrets);
    assertNoSecrets(proc.stderr, secrets);
    assertNoSecrets(logContent, secrets);
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("(f) prefer changes nothing and exits 2 when the preferred account lacks a required model", async () => {
  const server = await createMockServer((req, _body, res) => {
    if (req.url.startsWith("/token")) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end("{}");
      return;
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(modelsPayload(["claude-sonnet-5-5-medium"]));
  });

  const tempDir = makeTempAgentDir("keeper-prefer-missing-");
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const authFile = path.join(tempDir, "auth.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  const secrets = ["preferred-fresh-access-SECRET", "preferred-fresh-refresh-SECRET"];

  try {
    const now = Date.now();
    fs.writeFileSync(
      accountsFile,
      JSON.stringify(
        {
          version: 1,
          activeAccountId: "other@example.com",
          accounts: {
            "other@example.com": {
              accountId: "other@example.com",
              email: "other@example.com",
              access: "other-access-SECRET",
              refresh: "other-refresh-SECRET",
              expires: now + 50 * 60 * 1000,
              projectId: "project-other",
            },
            "preferred@example.com": {
              accountId: "preferred@example.com",
              email: "preferred@example.com",
              access: "preferred-fresh-access-SECRET",
              refresh: "preferred-fresh-refresh-SECRET",
              expires: now + 50 * 60 * 1000, // fresh: no refresh needed
              projectId: "project-pref",
            },
          },
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
    const storeBefore = fs.readFileSync(accountsFile, "utf8");

    const proc = await runKeeper(
      {
        ...process.env,
        HOME: tempDir,
        PI_CODING_AGENT_DIR: tempDir,
        ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
        ANTIGRAVITY_AUTH_FILE: authFile,
        ANTIGRAVITY_LOG_FILE: logFile,
        ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
        ANTIGRAVITY_TOKEN_URL: server.url,
        ANTIGRAVITY_CLIENT_ID: "id",
        ANTIGRAVITY_CLIENT_SECRET: "secret",
        ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5,claude-sonnet-5-5",
      },
      ["--prefer", "preferred@example.com"],
    );

    assert.equal(proc.status, 2, `stderr: ${proc.stderr}`);
    assert.equal(fs.readFileSync(accountsFile, "utf8"), storeBefore, "store must stay untouched");
    assert.equal(fs.existsSync(authFile), false, "auth.json must not be created");

    const logContent = fs.readFileSync(logFile, "utf8");
    assert.match(logContent, /email=preferred@example\.com result=missing-model:claude-opus-5-5/);
    assertNoSecrets(proc.stdout, secrets);
    assertNoSecrets(proc.stderr, secrets);
    assertNoSecrets(logContent, secrets);
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("(g) effort-suffixed ids satisfy their base required id", async () => {
  const server = await createMockServer((req, _body, res) => {
    if (req.url.startsWith("/token")) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end("{}");
      return;
    }
    // Only suffixed ids are offered; the base ids are what the operator configured.
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(modelsPayload(["claude-opus-5-5-low"]));
  });

  const tempDir = makeTempAgentDir("keeper-effort-");
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const authFile = path.join(tempDir, "auth.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  try {
    const now = Date.now();
    fs.writeFileSync(
      accountsFile,
      JSON.stringify(
        {
          version: 1,
          activeAccountId: "other@example.com",
          accounts: {
            "other@example.com": {
              accountId: "other@example.com",
              email: "other@example.com",
              access: "other-access",
              refresh: "other-refresh",
              expires: now + 50 * 60 * 1000,
            },
            "preferred@example.com": {
              accountId: "preferred@example.com",
              email: "preferred@example.com",
              access: "preferred-fresh-access",
              refresh: "preferred-fresh-refresh",
              expires: now + 50 * 60 * 1000,
              projectId: "project-pref",
            },
          },
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_AUTH_FILE: authFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
      ANTIGRAVITY_TOKEN_URL: server.url,
      ANTIGRAVITY_CLIENT_ID: "id",
      ANTIGRAVITY_CLIENT_SECRET: "secret",
      ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com",
      ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    });

    assert.equal(proc.status, 0, `stderr: ${proc.stderr}`);
    const updatedStore = JSON.parse(fs.readFileSync(accountsFile, "utf8"));
    assert.equal(updatedStore.activeAccountId, "preferred@example.com");
    const updatedAuth = JSON.parse(fs.readFileSync(authFile, "utf8"));
    assert.equal(updatedAuth.antigravity.email, "preferred@example.com");
    assert.match(fs.readFileSync(logFile, "utf8"), /result=activated/);
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("(h) active-account model verification exits 2 when a required model is missing", async () => {
  const server = await createMockServer((_req, _body, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(modelsPayload(["claude-sonnet-4-6"]));
  });

  const tempDir = makeTempAgentDir("keeper-verify-active-");
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const authFile = path.join(tempDir, "auth.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  try {
    const now = Date.now();
    fs.writeFileSync(
      accountsFile,
      JSON.stringify(
        {
          version: 1,
          activeAccountId: "active@example.com",
          accounts: {
            "active@example.com": {
              accountId: "active@example.com",
              email: "active@example.com",
              access: "active-access-SECRET",
              refresh: "active-refresh-SECRET",
              expires: now + 50 * 60 * 1000,
              projectId: "project-active",
            },
          },
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
    const storeBefore = fs.readFileSync(accountsFile, "utf8");

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_AUTH_FILE: authFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
      ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    });

    assert.equal(proc.status, 2, `stderr: ${proc.stderr}`);
    assert.equal(fs.readFileSync(accountsFile, "utf8"), storeBefore);
    assert.equal(fs.existsSync(authFile), false);
    assert.match(
      fs.readFileSync(logFile, "utf8"),
      /email=active@example\.com result=missing-model:claude-opus-5-5/,
    );
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("(i) an unavailable catalog does not fail prefer or active verification", async () => {
  const tempDir = makeTempAgentDir("keeper-offline-");
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const authFile = path.join(tempDir, "auth.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  // Port 1 is reserved and refuses connections immediately.
  const unreachable = "http://127.0.0.1:1/models";

  try {
    const now = Date.now();
    fs.writeFileSync(
      accountsFile,
      JSON.stringify(
        {
          version: 1,
          activeAccountId: "other@example.com",
          accounts: {
            "other@example.com": {
              accountId: "other@example.com",
              email: "other@example.com",
              access: "other-access",
              refresh: "other-refresh",
              expires: now + 50 * 60 * 1000,
            },
            "preferred@example.com": {
              accountId: "preferred@example.com",
              email: "preferred@example.com",
              access: "preferred-access",
              refresh: "preferred-refresh",
              expires: now + 50 * 60 * 1000,
              projectId: "project-pref",
            },
          },
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
    const storeBefore = fs.readFileSync(accountsFile, "utf8");

    const preferProc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_AUTH_FILE: authFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_MODELS_URL: unreachable,
      ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com",
      ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    });

    assert.equal(preferProc.status, 3, `stderr: ${preferProc.stderr}`);
    assert.equal(fs.readFileSync(accountsFile, "utf8"), storeBefore, "no switch on unavailable catalog");
    assert.equal(fs.existsSync(authFile), false);
    assert.match(fs.readFileSync(logFile, "utf8"), /result=model-check-unavailable/);

    const verifyProc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_MODELS_URL: unreachable,
      ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    });

    assert.equal(verifyProc.status, 3, `stderr: ${verifyProc.stderr}`);
    assert.match(fs.readFileSync(logFile, "utf8"), /result=model-check-unavailable/);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("(R1-002) a stale token on the active account is never reported as verified success", async (t) => {
  const s = scenario("keeper-active-stale-"); t.after(() => s.cleanup());
  const store = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
  store.accounts["other@example.com"].expires = Date.now() - 60 * 1000;
  fs.writeFileSync(s.accountsFile, JSON.stringify(store, null, 2), { mode: 0o600 });

  // The stored token is expired, so the catalogue is never queried, and the other
  // account cannot be verified either: the honest answer is failure, not success.
  const p = await runKeeper({
    ...s.env,
    ANTIGRAVITY_PREFERRED_ACCOUNT: "other@example.com",
    ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    ANTIGRAVITY_TOKEN_URL: "http://127.0.0.1:9/token",
    ANTIGRAVITY_MODELS_URL: "http://127.0.0.1:9/unreachable",
  });

  assert.equal(p.status, 3, p.stderr);
  assert.match(fs.readFileSync(s.logFile, "utf8"), /result=active-token-stale/);
  assert.doesNotMatch(fs.readFileSync(s.logFile, "utf8"), /result=activated/);
});

test("(R1-002) a stale active token moves the session to an account that can be verified", async (t) => {
  const s = scenario("keeper-stale-move-"); t.after(() => s.cleanup());
  const store = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
  store.accounts["other@example.com"].expires = Date.now() - 60 * 1000;
  fs.writeFileSync(s.accountsFile, JSON.stringify(store, null, 2), { mode: 0o600 });
  const server = await createMockServer((req, body, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(modelsPayload(["claude-opus-5-5-high", "claude-sonnet-5-5-high"]));
  });
  t.after(() => server.close());

  const p = await runKeeper({
    ...s.env,
    ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
    ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
  });

  assert.equal(p.status, 0, p.stderr);
  assert.equal(
    JSON.parse(fs.readFileSync(s.accountsFile, "utf8")).activeAccountId,
    "preferred@example.com",
    "the only account whose capability can be proven is now active",
  );
  assert.equal(
    JSON.parse(fs.readFileSync(s.authFile, "utf8")).antigravity.email,
    "preferred@example.com",
  );
});

test("(R3-001) nothing compatible and no active account fails instead of reporting success", async (t) => {
  const s = scenario("keeper-no-active-"); t.after(() => s.cleanup());
  const store = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
  delete store.activeAccountId;
  fs.writeFileSync(s.accountsFile, JSON.stringify(store, null, 2), { mode: 0o600 });
  const server = await createMockServer((req, body, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(modelsPayload(["claude-opus-4-6-high"]));
  });
  t.after(() => server.close());

  const p = await runKeeper({
    ...s.env,
    ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
    ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
  });

  assert.equal(p.status, 2, p.stderr);
  assert.match(fs.readFileSync(s.logFile, "utf8"), /result=missing-model:claude-opus-5-5/);
});

test("(R1-001) unprefixed OAuth variables cannot redirect the exchange", () => {
  // Inherited bare names are ignored, so with no prefixed values and no oauth file the
  // resolver refuses to build a request at all instead of posting the refresh token to
  // whatever URL the environment happens to carry.
  assert.throws(
    () => resolveOAuthConstants({
      TOKEN_URL: "https://attacker.invalid/token",
      CLIENT_ID: "attacker-id",
      CLIENT_SECRET: "attacker-secret",
    }, "/nonexistent/.config/pi-antigravity/oauth.ts"),
    /missing TOKEN_URL, CLIENT_ID, CLIENT_SECRET/,
  );
});

test("(REG-002) an empty store with a requirement names the model it cannot serve", async (t) => {
  const s = scenario("keeper-empty-store-"); t.after(() => s.cleanup());
  fs.writeFileSync(s.accountsFile, JSON.stringify({ version: 1, accounts: {} }, null, 2), { mode: 0o600 });

  const p = await runKeeper({
    ...s.env,
    ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    ANTIGRAVITY_MODELS_URL: "http://127.0.0.1:9/unreachable",
  });

  assert.equal(p.status, 2, p.stderr);
  assert.match(p.stderr, /no account serves claude-opus-5-5/);
});

test("(REG-002) without a requirement the compatibility check stays inert", async (t) => {
  const s = scenario("keeper-no-requirement-"); t.after(() => s.cleanup());
  const result = await ensureCompatibleAccount({
    ...s.env,
    accountsPath: s.accountsFile,
    requiredModels: [],
  });
  assert.equal(result.exitCode, 0, "renewal mode owns this case");
  assert.equal(result.result, "no-active-account");
});

test("(auto) keeps the active account when it already serves the models", async (t) => {
  const s = scenario("keeper-auto-ok-"); t.after(() => s.cleanup());
  const server = await createMockServer((req, body, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(modelsPayload(["claude-opus-5-5-high", "claude-sonnet-5-5-high"]));
  });
  t.after(() => server.close());

  const p = await runKeeper({
    ...s.env,
    ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
    ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5,claude-sonnet-5-5",
  });

  assert.equal(p.status, 0, p.stderr);
  assert.equal(JSON.parse(fs.readFileSync(s.accountsFile, "utf8")).activeAccountId, "other@example.com");
  assert.equal(fs.existsSync(s.authFile), false, "nothing moved, so no credential is written");
});

test("(auto) moves off an account that cannot serve a required model", async (t) => {
  const s = scenario("keeper-auto-move-"); t.after(() => s.cleanup());
  const server = await createMockServer((req, body, res) => {
    const authorization = String(req.headers.authorization || "");
    const ids = authorization.includes("other@example.com")
      ? ["claude-opus-4-6-high"]
      : ["claude-opus-5-5-high", "claude-sonnet-5-5-high"];
    res.writeHead(200, { "content-type": "application/json" });
    res.end(modelsPayload(ids));
  });
  t.after(() => server.close());

  const p = await runKeeper({
    ...s.env,
    ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
    ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5,claude-sonnet-5-5",
  });

  assert.equal(p.status, 0, p.stderr);
  assert.equal(JSON.parse(fs.readFileSync(s.accountsFile, "utf8")).activeAccountId, "preferred@example.com");
  assert.equal(JSON.parse(fs.readFileSync(s.authFile, "utf8")).antigravity.email, "preferred@example.com");
});

test("(j) no output or log line ever contains a token", async () => {
  const secrets = [
    "unique-access-token-XYZZY",
    "unique-refresh-token-XYZZY",
    "unique-rotated-refresh-XYZZY",
    "unique-client-secret-XYZZY",
  ];

  const server = await createMockServer((req, _body, res) => {
    if (req.url.startsWith("/token")) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          access_token: secrets[0],
          refresh_token: secrets[2],
          expires_in: 3600,
        }),
      );
      return;
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(modelsPayload(["claude-opus-5-5-high"]));
  });

  const tempDir = makeTempAgentDir("keeper-secrets-");
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  const authFile = path.join(tempDir, "auth.json");
  const logFile = path.join(tempDir, "antigravity-keeper.log");

  try {
    const now = Date.now();
    fs.writeFileSync(
      accountsFile,
      JSON.stringify(
        {
          version: 1,
          activeAccountId: "other@example.com",
          accounts: {
            "other@example.com": {
              accountId: "other@example.com",
              email: "other@example.com",
              access: "other-access",
              refresh: "other-refresh",
              expires: now + 50 * 60 * 1000,
            },
            "preferred@example.com": {
              accountId: "preferred@example.com",
              email: "preferred@example.com",
              access: secrets[1],
              refresh: secrets[1],
              expires: now + 60 * 1000,
              projectId: "project-pref",
            },
          },
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );

    const proc = await runKeeper({
      ...process.env,
      HOME: tempDir,
      PI_CODING_AGENT_DIR: tempDir,
      ANTIGRAVITY_ACCOUNTS_FILE: accountsFile,
      ANTIGRAVITY_AUTH_FILE: authFile,
      ANTIGRAVITY_LOG_FILE: logFile,
      ANTIGRAVITY_TOKEN_URL: server.url,
      ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
      ANTIGRAVITY_CLIENT_ID: "id",
      ANTIGRAVITY_CLIENT_SECRET: secrets[3],
      ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com",
      ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    });

    assert.equal(proc.status, 0, `stderr: ${proc.stderr}`);
    const logContent = fs.readFileSync(logFile, "utf8");
    assertNoSecrets(proc.stdout, secrets);
    assertNoSecrets(proc.stderr, secrets);
    assertNoSecrets(logContent, secrets);
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("extracts the selectable key when the payload value carries an internal enum", () => {
  const payload = {
    models: {
      "claude-opus-5-5-high": { displayName: "Claude Opus 5.5 (High)", model: "MODEL_PLACEHOLDER_M402" },
      "claude-sonnet-5-5-low": { displayName: "Claude Sonnet 5.5 (Low)", model: "MODEL_PLACEHOLDER_M403" },
      "gemini-3.8-flash": { displayName: "Gemini 3.8 Flash", model: "MODEL_PLACEHOLDER_M318" },
    },
  };
  const ids = extractModelIds(payload);
  assert.ok(ids.has("claude-opus-5-5-high"), "the friendly key must be collected");
  assert.equal(findMissingModels(ids, ["claude-opus-5-5", "claude-sonnet-5-5"]).length, 0);
});

test("(--prefer with no value exits 64 and makes no request)", async () => {
  let requests = 0;
  const server = await createMockServer((_req, _body, res) => { requests++; res.end("{}"); });
  const s = scenario("keeper-cli-novalue-", 60 * 1000);
  try {
    const before = fs.readFileSync(s.accountsFile, "utf8");
    const proc = await runKeeper({ ...s.env, ANTIGRAVITY_TOKEN_URL: server.url }, ["--prefer"]);
    assert.equal(proc.status, 64, proc.stderr);
    assert.match(proc.stderr, /--prefer/);
    assert.equal(requests, 0, "a usage error must not contact the network");
    assert.equal(fs.readFileSync(s.accountsFile, "utf8"), before);
    assert.equal(fs.existsSync(s.logFile), false);
  } finally { await server.close(); s.cleanup(); }
});

test("(empty --prefer= and unknown options exit 64)", async () => {
  const s = scenario("keeper-cli-empty-");
  try {
    const before = fs.readFileSync(s.accountsFile, "utf8");
    const empty = await runKeeper(s.env, ["--prefer="]);
    const unknown = await runKeeper(s.env, ["--bogus"]);
    assert.equal(empty.status, 64, empty.stderr);
    assert.match(empty.stderr, /--prefer/);
    assert.equal(unknown.status, 64, unknown.stderr);
    assert.match(unknown.stderr, /unknown option/);
    assert.equal(fs.readFileSync(s.accountsFile, "utf8"), before);
    assert.equal(fs.existsSync(s.logFile), false);
  } finally { s.cleanup(); }
});

test("(rotated refresh token survives a later catalog failure)", async () => {
  const server = await createMockServer((req, _body, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(req.url.startsWith("/token")
      ? JSON.stringify({ access_token: "rotated-access", refresh_token: "rotated-refresh", expires_in: 3600 })
      : modelsPayload(["claude-sonnet-5-5"]));
  });
  const s = scenario("keeper-rotate-", 60 * 1000);
  try {
    const proc = await runKeeper({
      ...s.env, ANTIGRAVITY_TOKEN_URL: server.url, ANTIGRAVITY_MODELS_URL: `${server.base}/models`,
      ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com", ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5",
    });
    assert.equal(proc.status, 2, proc.stderr);
    const store = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    assert.equal(store.activeAccountId, "other@example.com");
    assert.equal(store.accounts["preferred@example.com"].access, "rotated-access");
    assert.equal(store.accounts["preferred@example.com"].refresh, "rotated-refresh");
    assert.equal(fs.existsSync(s.authFile), false);
  } finally { await server.close(); s.cleanup(); }
});

test("(credential-write failure keeps activeAccountId and exits non-zero)", async () => {
  const s = scenario("keeper-authfail-");
  try {
    const before = fs.readFileSync(s.accountsFile, "utf8");
    fs.writeFileSync(s.authFile, "{ not json", { mode: 0o600 });
    const authBefore = fs.readFileSync(s.authFile, "utf8");
    const proc = await runKeeper({
      ...s.env, ANTIGRAVITY_TOKEN_URL: "http://127.0.0.1:1/token",
      ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com",
    });
    assert.notEqual(proc.status, 0, "credential failure must fail the run");
    assert.match(proc.stderr, /credential write failed/);
    assert.equal(fs.readFileSync(s.accountsFile, "utf8"), before);
    assert.equal(fs.readFileSync(s.authFile, "utf8"), authBefore);
    assert.match(fs.readFileSync(s.logFile, "utf8"), /result=credential-write-failed/);
  } finally { s.cleanup(); }
});

/** Token server whose first response blocks until `release()` is called. */
async function gatedTokenServer(payload) {
  let release, seen;
  const gate = new Promise((r) => { release = r; });
  const requestSeen = new Promise((r) => { seen = r; });
  const server = await createMockServer(async (_req, _body, res) => {
    seen();
    await gate;
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(payload));
  });
  return { server, requestSeen, release };
}

test("(S4) a configured preferred account absent from the store fails loudly and writes nothing", async () => {
  const s = scenario("keeper-prefer-absent-");
  try {
    const before = fs.readFileSync(s.accountsFile, "utf8");
    const proc = await runKeeper({ ...s.env, ANTIGRAVITY_PREFERRED_ACCOUNT: "ghost@example.com" });
    assert.equal(proc.status, 1, proc.stderr);
    assert.match(proc.stderr, /preferred account not found/);
    assert.equal(fs.readFileSync(s.accountsFile, "utf8"), before);
    assert.ok(!fs.existsSync(s.authFile));
    assert.match(fs.readFileSync(s.logFile, "utf8"), /result=preferred-account-missing/);
  } finally { s.cleanup(); }
});

test("(S5) an aliased activeAccountId is not refreshed by the timer", async () => {
  let requests = 0;
  const server = await createMockServer((_req, _body, res) => {
    requests++; res.end(JSON.stringify({ access_token: "unexpected", expires_in: 3600 }));
  });
  const tempDir = makeTempAgentDir("keeper-alias-active-");
  const accountsFile = path.join(tempDir, "antigravity-accounts.json");
  try {
    // The map key is neither the email nor the accountId the store points at.
    for (const alias of ["steady@example.com", "steady-id"]) {
      fs.writeFileSync(accountsFile, JSON.stringify({ version: 1, activeAccountId: alias, accounts: {
        "steady-account": { accountId: "steady-id", email: "steady@example.com", access: "a", refresh: "r", expires: Date.now() + 60000 },
      } }, null, 2), { mode: 0o600 });
      const before = fs.readFileSync(accountsFile, "utf8");
      const proc = await runKeeper({ ...process.env, PI_CODING_AGENT_DIR: tempDir, ANTIGRAVITY_ACCOUNTS_FILE: accountsFile, ANTIGRAVITY_TOKEN_URL: server.url, ANTIGRAVITY_CLIENT_ID: "id", ANTIGRAVITY_CLIENT_SECRET: "secret" });
      assert.equal(proc.status, 0, proc.stderr);
      assert.equal(fs.readFileSync(accountsFile, "utf8"), before, `alias ${alias} must not be renewed`);
    }
    assert.equal(requests, 0);
  } finally { await server.close(); fs.rmSync(tempDir, { recursive: true, force: true }); }
});

test("(S4) a configured preferred account with no accounts store fails loudly", async () => {
  const s = scenario("keeper-prefer-nostore-", 60 * 1000);
  fs.rmSync(s.accountsFile, { force: true });
  try {
    const proc = await runKeeper({ ...s.env, ANTIGRAVITY_PREFERRED_ACCOUNT: "ghost@example.com" });
    assert.notEqual(proc.status, 0, "must not report success without activating the requested account");
    assert.match(proc.stderr, /not found/i);
    assert.equal(fs.existsSync(s.accountsFile), false, "no store may be created");
    assert.equal(fs.existsSync(s.authFile), false, "no credential may be written");
  } finally { s.cleanup(); }
});

test("(S7) the credential written on activation reflects the freshest account snapshot", async () => {
  const { server, requestSeen, release } = await gatedTokenServer({ access_token: "fresh-access", refresh_token: "fresh-refresh", expires_in: 3600 });
  const s = scenario("keeper-fresh-credential-", 60 * 1000); // stale preferred, must refresh
  try {
    const running = runKeeper({ ...s.env, ANTIGRAVITY_TOKEN_URL: server.url, ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com" });
    await requestSeen;
    const concurrent = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    concurrent.accounts["preferred@example.com"].projectId = "project-fresh";
    fs.writeFileSync(s.accountsFile, JSON.stringify(concurrent, null, 2), { mode: 0o600 });
    release();
    assert.equal((await running).status, 0);
    const auth = JSON.parse(fs.readFileSync(s.authFile, "utf8"));
    assert.equal(auth.antigravity.projectId, "project-fresh");
    assert.equal(auth.antigravity.access, "fresh-access");
    assert.equal(JSON.parse(fs.readFileSync(s.accountsFile, "utf8")).accounts["preferred@example.com"].projectId, "project-fresh");
  } finally { await server.close(); s.cleanup(); }
});

test("a renewal preserves concurrent unrelated writes and still persists a rotated refresh token", async () => {
  const { server, requestSeen, release } = await gatedTokenServer({
    access_token: "keeper-rotated-access",
    refresh_token: "keeper-rotated-refresh",
    expires_in: 3600,
  });
  const s = scenario("keeper-reread-", 60 * 1000); // preferred is expiring and not active
  try {
    const running = runKeeper({ ...s.env, ANTIGRAVITY_TOKEN_URL: server.url });
    await requestSeen;
    // The store keeps changing while the refresh is in flight; the last write
    // moves a field the keeper does not own and must not clobber.
    for (const tick of [1, 2, 3]) {
      const concurrent = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
      concurrent.accounts["other@example.com"].concurrentTick = tick;
      concurrent.accounts["other@example.com"].lastUsedAt = 9000 + tick;
      fs.writeFileSync(s.accountsFile, JSON.stringify(concurrent, null, 2), { mode: 0o600 });
    }
    release();
    const proc = await running;

    assert.equal(proc.status, 0, proc.stderr);
    const final = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    // The rotated token landed even though the store changed during the call.
    assert.equal(final.accounts["preferred@example.com"].access, "keeper-rotated-access");
    assert.equal(final.accounts["preferred@example.com"].refresh, "keeper-rotated-refresh");
    // The concurrent write to a foreign field survived the merge.
    assert.equal(final.accounts["other@example.com"].concurrentTick, 3);
    assert.equal(final.accounts["other@example.com"].lastUsedAt, 9003);
    assert.equal(final.activeAccountId, "other@example.com");
    assert.match(fs.readFileSync(s.logFile, "utf8"), /email=preferred@example\.com result=ok/);
  } finally { await server.close(); s.cleanup(); }
});

test("(D3) a renewal skips an account that became active mid-refresh and keeps the plugin token", async () => {
  const { server, requestSeen, release } = await gatedTokenServer({
    access_token: "keeper-stale-access",
    refresh_token: "keeper-stale-refresh",
    expires_in: 3600,
  });
  const s = scenario("keeper-skip-active-", 60 * 1000); // preferred is expiring and not active
  try {
    const running = runKeeper({ ...s.env, ANTIGRAVITY_TOKEN_URL: server.url });
    await requestSeen;
    // pi-antigravity fails over to `preferred` and refreshes it while we are in flight.
    const concurrent = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    concurrent.activeAccountId = "preferred@example.com";
    concurrent.accounts["preferred@example.com"].access = "plugin-active-access";
    concurrent.accounts["preferred@example.com"].refresh = "plugin-active-refresh";
    concurrent.accounts["preferred@example.com"].expires = Date.now() + 55 * 60 * 1000;
    fs.writeFileSync(s.accountsFile, JSON.stringify(concurrent, null, 2), { mode: 0o600 });
    release();
    const proc = await running;

    assert.equal(proc.status, 0, proc.stderr);
    const final = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    assert.equal(final.activeAccountId, "preferred@example.com");
    // The keeper's older refreshed token must not overwrite the plugin's.
    assert.equal(final.accounts["preferred@example.com"].access, "plugin-active-access");
    assert.equal(final.accounts["preferred@example.com"].refresh, "plugin-active-refresh");
    assert.match(fs.readFileSync(s.logFile, "utf8"), /email=preferred@example\.com result=skip-now-active/);
  } finally { await server.close(); s.cleanup(); }
});

test("(D3) prefer skips the early token write when the account becomes active mid-refresh", async () => {
  const { server, requestSeen, release } = await gatedTokenServer({
    access_token: "keeper-stale-access",
    refresh_token: "keeper-stale-refresh",
    expires_in: 3600,
  });
  const s = scenario("keeper-prefer-active-", 60 * 1000); // preferred is expiring and not active
  try {
    const running = runKeeper({ ...s.env, ANTIGRAVITY_TOKEN_URL: server.url, ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com" });
    await requestSeen;
    const concurrent = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    concurrent.activeAccountId = "preferred@example.com";
    concurrent.accounts["preferred@example.com"].access = "plugin-active-access";
    concurrent.accounts["preferred@example.com"].refresh = "plugin-active-refresh";
    concurrent.accounts["preferred@example.com"].expires = Date.now() + 55 * 60 * 1000;
    fs.writeFileSync(s.accountsFile, JSON.stringify(concurrent, null, 2), { mode: 0o600 });
    release();
    const proc = await running;

    assert.equal(proc.status, 0, proc.stderr);
    const final = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    assert.equal(final.accounts["preferred@example.com"].access, "plugin-active-access");
    assert.equal(final.accounts["preferred@example.com"].refresh, "plugin-active-refresh");
    // The credential mirrors the plugin's fresh snapshot, not our older refresh.
    const auth = JSON.parse(fs.readFileSync(s.authFile, "utf8"));
    assert.equal(auth.antigravity.access, "plugin-active-access");
    assert.equal(auth.antigravity.refresh, "plugin-active-refresh");
    assert.match(fs.readFileSync(s.logFile, "utf8"), /email=preferred@example\.com result=skip-now-active/);
  } finally { await server.close(); s.cleanup(); }
});

test("(a concurrent activeAccountId change during renewal survives)", async () => {
  let release;
  let seen;
  const gate = new Promise((resolve) => { release = resolve; });
  const requestSeen = new Promise((resolve) => { seen = resolve; });
  const server = await createMockServer(async (_req, _body, res) => {
    seen();
    await gate;
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ access_token: "renewed-access", refresh_token: "renewed-refresh", expires_in: 3600 }));
  });
  const s = scenario("keeper-concurrent-");
  try {
    const store = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    store.activeAccountId = "active-a@example.com";
    store.accounts["expiring@example.com"] = {
      accountId: "expiring@example.com", email: "expiring@example.com",
      access: "expiring-access", refresh: "expiring-refresh", expires: Date.now() + 60 * 1000, projectId: "project-exp",
    };
    fs.writeFileSync(s.accountsFile, JSON.stringify(store, null, 2), { mode: 0o600 });

    const running = runKeeper({ ...s.env, ANTIGRAVITY_TOKEN_URL: server.url });
    await requestSeen;
    const concurrent = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    concurrent.activeAccountId = "other@example.com";
    fs.writeFileSync(s.accountsFile, JSON.stringify(concurrent, null, 2), { mode: 0o600 });
    release();
    const proc = await running;

    assert.equal(proc.status, 0, proc.stderr);
    const final = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
    assert.equal(final.activeAccountId, "other@example.com");
    assert.equal(final.accounts["expiring@example.com"].access, "renewed-access");
    assert.equal(final.accounts["expiring@example.com"].refresh, "renewed-refresh");
  } finally { await server.close(); s.cleanup(); }
});

test("(R4-002) blank --prefer values exit 64 with no side effect and --prefer= still activates", async (t) => {
  const s = scenario("keeper-blank-prefer-"); t.after(() => s.cleanup());
  const before = fs.readFileSync(s.accountsFile, "utf8");
  for (const args of [["--prefer", ""], ["--prefer", "   "], ["--prefer=   "]]) {
    const p = await runKeeper(s.env, args);
    assert.equal(p.status, 64, p.stderr); assert.match(p.stderr, /--prefer/);
  }
  assert.equal(fs.readFileSync(s.accountsFile, "utf8"), before); assert.ok(!fs.existsSync(s.logFile));
  const ok = await runKeeper(s.env, ["--prefer=preferred@example.com"]);
  assert.equal(ok.status, 0, ok.stderr); assert.equal(JSON.parse(fs.readFileSync(s.accountsFile, "utf8")).activeAccountId, "preferred@example.com");
});

test("(R4-003) a suffixed requirement needs that exact id while a base requirement accepts any suffix", async (t) => {
  const server = await createMockServer((req, _b, res) => { res.writeHead(200); res.end(req.url.startsWith("/token") ? "{}" : modelsPayload(["claude-opus-5-5-low"])); }); t.after(() => server.close());
  const s = scenario("keeper-directional-"); t.after(() => s.cleanup());
  const env = { ...s.env, ANTIGRAVITY_MODELS_URL: `${server.base}/models` };
  const strict = await runKeeper({ ...env, ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5-high" });
  assert.equal(strict.status, 2, strict.stderr); assert.match(fs.readFileSync(s.logFile, "utf8"), /missing-model:claude-opus-5-5-high/);
  const base = await runKeeper({ ...env, ANTIGRAVITY_REQUIRED_MODELS: "claude-opus-5-5", ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com" });
  assert.equal(base.status, 0, base.stderr); assert.equal(JSON.parse(fs.readFileSync(s.accountsFile, "utf8")).activeAccountId, "preferred@example.com");
});

test("(R4-005) a failing log write cannot stop a rotated refresh token from being persisted", async (t) => {
  const server = await createMockServer((_q, _b, res) => { res.writeHead(200); res.end(JSON.stringify({ access_token: "logfail-access", refresh_token: "logfail-refresh", expires_in: 3600 })); });
  t.after(() => server.close());
  const s = scenario("keeper-logfail-", 60 * 1000); t.after(() => s.cleanup());
  const blocker = path.join(path.dirname(s.logFile), "blocker"); fs.writeFileSync(blocker, "x", { mode: 0o600 });
  const p = await runKeeper({ ...s.env, ANTIGRAVITY_TOKEN_URL: server.url, ANTIGRAVITY_LOG_FILE: path.join(blocker, "keeper.log") });
  assert.equal(p.status, 0, p.stderr);
  const store = JSON.parse(fs.readFileSync(s.accountsFile, "utf8"));
  assert.equal(store.accounts["preferred@example.com"].refresh, "logfail-refresh"); assert.equal(store.activeAccountId, "other@example.com");
});

test("(R1-001) withStoreRetry retries instead of clobbering a store changed mid-window", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "keeper-cas-")); t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = path.join(dir, "antigravity-accounts.json");
  const acct = (id) => ({ accountId: id, email: id, access: `${id}-access`, refresh: `${id}-refresh`, expires: 1 });
  fs.writeFileSync(store, JSON.stringify({ version: 1, activeAccountId: "a@x", accounts: { "a@x": acct("a@x") } }, null, 2), { mode: 0o600 });
  const result = await withStoreRetry(store, (target) => {
    if (!target.accounts["b@x"]) { // the plugin lands a write between our read and our rename
      const plugin = JSON.parse(fs.readFileSync(store, "utf8")); plugin.activeAccountId = "b@x"; plugin.accounts["b@x"] = acct("b@x");
      fs.writeFileSync(store, JSON.stringify(plugin, null, 2), { mode: 0o600 });
    }
    target.accounts["a@x"].access = "keeper-access";
    return { dirty: true, skipped: [], verified: (a) => a.accounts["a@x"].access === "keeper-access" };
  });
  assert.equal(result.ok, true); const final = JSON.parse(fs.readFileSync(store, "utf8"));
  assert.equal(final.activeAccountId, "b@x"); assert.equal(final.accounts["a@x"].access, "keeper-access");
});

test("(R3-001) the credential is never written before the store commit and a failed mirror is compensated", async (t) => {
  const s = scenario("keeper-converge-"); t.after(() => s.cleanup());
  const dir = path.dirname(s.accountsFile), authDir = path.join(dir, "auth-ro"), authFile = path.join(authDir, "auth.json");
  fs.mkdirSync(authDir);
  fs.writeFileSync(authFile, JSON.stringify({ antigravity: { type: "oauth", email: "other@example.com", access: "other-access", refresh: "other-refresh", expires: Date.now() + 3000000, projectId: "project-other" } }, null, 2), { mode: 0o600 });
  const authBefore = fs.readFileSync(authFile, "utf8");
  const env = { ...s.env, ANTIGRAVITY_AUTH_FILE: authFile, ANTIGRAVITY_PREFERRED_ACCOUNT: "preferred@example.com" };
  fs.chmodSync(dir, 0o500); const locked = await runKeeper(env); fs.chmodSync(dir, 0o700);
  assert.notEqual(locked.status, 0, locked.stderr); assert.equal(fs.readFileSync(authFile, "utf8"), authBefore, "no credential write before the store commit");
  fs.chmodSync(authDir, 0o500); const mirror = await runKeeper(env); fs.chmodSync(authDir, 0o700);
  assert.notEqual(mirror.status, 0, mirror.stderr); assert.match(mirror.stderr, /active account restored/);
  assert.equal(JSON.parse(fs.readFileSync(s.accountsFile, "utf8")).activeAccountId, "other@example.com");
});

test("(R3-001) healing runs when leadership is asserted, and (R3-003) never on the renewal path", async (t) => {
  const disagreeing = (s) => {
    const store = JSON.parse(fs.readFileSync(s.accountsFile, "utf8")), other = store.accounts["other@example.com"];
    fs.writeFileSync(s.authFile, JSON.stringify({ openai: { type: "api_key", key: "keep" }, antigravity: { type: "oauth", email: "preferred@example.com", access: "preferred-access", refresh: "preferred-refresh", expires: other.expires, projectId: "project-pref" } }, null, 2), { mode: 0o600 });
    return fs.readFileSync(s.accountsFile, "utf8");
  };

  const s = scenario("keeper-heal-"); t.after(() => s.cleanup());
  const before = disagreeing(s);
  const p = await runKeeper({ ...s.env, ANTIGRAVITY_PREFERRED_ACCOUNT: "other@example.com" });
  assert.equal(p.status, 0, p.stderr);
  const auth = JSON.parse(fs.readFileSync(s.authFile, "utf8"));
  assert.equal(auth.antigravity.access, "other@example.com/access"); assert.deepEqual(auth.openai, { type: "api_key", key: "keep" });
  assert.equal(fs.readFileSync(s.accountsFile, "utf8"), before); assert.match(fs.readFileSync(s.logFile, "utf8"), /result=healed/);

  // R3-003: the renewal path belongs to the plugin. A credential that names another
  // account may be its quota failover, so the keeper must leave it untouched.
  const r = scenario("keeper-no-heal-"); t.after(() => r.cleanup());
  disagreeing(r);
  const untouched = fs.readFileSync(r.authFile, "utf8");
  const renewal = await runKeeper(r.env);
  assert.equal(renewal.status, 0, renewal.stderr);
  assert.equal(fs.readFileSync(r.authFile, "utf8"), untouched, "the renewal path never rewrites the credential");
  assert.doesNotMatch(fs.existsSync(r.logFile) ? fs.readFileSync(r.logFile, "utf8") : "", /result=healed/);

  // R3-001: a prefer that fails must leave the credential exactly as it was. The keeper
  // promises untouched state when it cannot assert leadership, so healing cannot run first.
  const f = scenario("keeper-failed-prefer-"); t.after(() => f.cleanup());
  disagreeing(f);
  const beforeFailed = fs.readFileSync(f.authFile, "utf8");
  const failed = await runKeeper({ ...f.env, ANTIGRAVITY_PREFERRED_ACCOUNT: "ghost@example.com" });
  assert.notEqual(failed.status, 0, failed.stderr);
  assert.equal(fs.readFileSync(f.authFile, "utf8"), beforeFailed, "a failed prefer never rewrites the credential");
});
