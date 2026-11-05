// Tests drive `vibe-token` as a subprocess against a fake OIDC issuer and a fake
// Mistral API, so every assertion is made through the CLI's public surface and
// the files it leaves behind. Nothing here reads the module's internals.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), "mistral-vibe-auth.mjs");

/** One fake issuer + API. Each scenario resets its counters. */
function createFakeServer() {
  const state = {
    exchangeCount: 0,
    refreshCount: 0,
    challenge: null,
    refreshToken: null,
    serial: 0,
    bearerStatus: 200,
    // Lifetimes handed to new tokens, in seconds.
    accessLifetime: 3600,
    idTokenLifetime: 3600,
    lastBearer: null,
  };

  function makeIdToken(lifetime) {
    state.serial += 1;
    const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
    const payload = Buffer.from(
      JSON.stringify({
        sub: "sub-test",
        exp: Math.floor(Date.now() / 1000) + lifetime,
        serial: state.serial,
      }),
    ).toString("base64url");
    return `${header}.${payload}.sig-${state.serial}`;
  }

  function issue() {
    state.refreshToken = `refresh-${state.serial + 1}`;
    return {
      access_token: `access-${state.serial + 1}`,
      refresh_token: state.refreshToken,
      id_token: makeIdToken(state.idTokenLifetime),
      token_type: "Bearer",
      expires_in: state.accessLifetime,
    };
  }

  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    let body = "";
    request.on("data", (chunk) => (body += chunk));
    request.on("end", async () => {
      const json = (status, payload) => {
        response.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(payload));
      };

      if (url.pathname === "/.well-known/openid-configuration") {
        return json(200, {
          issuer: state.issuer,
          authorization_endpoint: `${state.issuer}/oauth2/auth`,
          token_endpoint: `${state.issuer}/oauth2/token`,
        });
      }

      if (url.pathname === "/oauth2/token") {
        const form = new URLSearchParams(body);
        if (form.get("grant_type") === "authorization_code") {
          state.exchangeCount += 1;
          if (form.get("code") !== "test-code") {
            return json(400, { error: "invalid_grant", error_description: "bad code" });
          }
          if (state.redirectUri && form.get("redirect_uri") !== state.redirectUri) {
            return json(400, { error: "invalid_grant", error_description: "redirect_uri mismatch" });
          }
          const verifier = form.get("code_verifier") || "";
          const computed = createHash("sha256").update(verifier).digest("base64url");
          if (!state.challenge || computed !== state.challenge) {
            return json(400, { error: "invalid_grant", error_description: "pkce mismatch" });
          }
          return json(200, issue());
        }
        if (form.get("grant_type") === "refresh_token") {
          state.refreshCount += 1;
          if (form.get("refresh_token") !== state.refreshToken) {
            return json(400, { error: "invalid_grant", error_description: "refresh token already used" });
          }
          // Widen the window a concurrent racer would slip through.
          await new Promise((resolve) => setTimeout(resolve, 150));
          return json(200, issue());
        }
        return json(400, { error: "unsupported_grant_type" });
      }

      if (url.pathname === "/v1/users/me/workspaces") {
        if (state.onWorkspaces) await state.onWorkspaces();
        state.lastBearer = request.headers.authorization || null;
        if (state.bearerStatus !== 200) return json(state.bearerStatus, { error: "denied" });
        return json(200, { workspaces: [{ id: "ws-test", organization_id: "org-test" }] });
      }

      return json(404, { error: "not found" });
    });
  });

  return { server, state };
}

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

/** A port nothing else holds right now, for the CLI's loopback callback. */
async function freePort() {
  const probe = http.createServer();
  const port = await listen(probe);
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

function runCli(args, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CLI, ...args], { env: { ...process.env, ...env } });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.emit("spawned");
  });
}

/** Runs `login --no-browser`, plays the browser, and waits for the CLI. */
function loginWithFakeBrowser(env, port, fakeState, beforeCallback) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CLI, "login", "--no-browser", "--port", String(port)], {
      env: { ...process.env, ...env },
    });
    let stdout = "";
    let stderr = "";
    let played = false;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`login never printed an authorize URL. stderr: ${stderr}`));
    }, 15_000);

    const playBrowser = async () => {
      const match = stderr.match(/https?:\/\/\S+/);
      if (!match || played) return;
      played = true;
      if (beforeCallback) await beforeCallback();
      const authorize = new URL(match[0]);
      fakeState.challenge = authorize.searchParams.get("code_challenge");
      fakeState.redirectUri = authorize.searchParams.get("redirect_uri");
      const state = authorize.searchParams.get("state");
      const redirect = new URL(authorize.searchParams.get("redirect_uri"));
      redirect.searchParams.set("code", "test-code");
      redirect.searchParams.set("state", state);
      try {
        const response = await fetch(redirect);
        assert.equal(response.status, 200);
      } catch (error) {
        clearTimeout(timer);
        child.kill("SIGKILL");
        reject(error);
      }
    };

    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
      void playBrowser();
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, authorizeUrl: (stderr.match(/https?:\/\/\S+/) || [])[0] });
    });
  });
}

function writeExpiredStore(dir, state, { lifetime = 10 } = {}) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
  const payload = Buffer.from(
    JSON.stringify({ sub: "sub-test", exp: Math.floor(Date.now() / 1000) + lifetime }),
  ).toString("base64url");
  const store = {
    version: 1,
    issuer: "fake",
    client_id: "fake-client",
    audience: "fake-audience",
    subject: "sub-test",
    access_token: "access-seed",
    refresh_token: "refresh-seed",
    id_token: `${header}.${payload}.sig-seed`,
    expires_at: Math.floor(Date.now() / 1000) + lifetime,
    id_token_expires_at: Math.floor(Date.now() / 1000) + lifetime,
    tenant: { organization_id: "org-test", workspace_id: "ws-test" },
  };
  fs.writeFileSync(path.join(dir, "credentials.json"), JSON.stringify(store), { mode: 0o600 });
  state.refreshToken = store.refresh_token;
  return store;
}

describe("vibe-token", () => {
  let fake;
  let issuer;
  let baseEnv;
  let tempRoot;

  before(async () => {
    fake = createFakeServer();
    const port = await listen(fake.server);
    issuer = `http://127.0.0.1:${port}`;
    fake.state.issuer = issuer;
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-token-test-"));
  });

  after(async () => {
    await new Promise((resolve) => fake.server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  });

  function scenario() {
    const dir = fs.mkdtempSync(path.join(tempRoot, "case-"));
    fake.state.exchangeCount = 0;
    fake.state.refreshCount = 0;
    fake.state.challenge = null;
    fake.state.redirectUri = null;
    fake.state.onWorkspaces = null;
    fake.state.refreshToken = null;
    fake.state.bearerStatus = 200;
    fake.state.accessLifetime = 3600;
    fake.state.idTokenLifetime = 3600;
    baseEnv = {
      VIBE_TOKEN_DIR: dir,
      VIBE_TOKEN_ISSUER: issuer,
      VIBE_TOKEN_API_BASE: issuer,
      VIBE_TOKEN_AUDIENCE: "fake-audience",
    };
    return dir;
  }

  test("login exchanges the code with PKCE and stores 0600 credentials", async () => {
    const dir = scenario();
    const port = await freePort();
    const result = await loginWithFakeBrowser(baseEnv, port, fake.state);

    assert.equal(result.code, 0, `login failed: ${result.stderr}`);
    assert.equal(fake.state.exchangeCount, 1, "expected exactly one code exchange");

    const authorize = new URL(result.authorizeUrl);
    assert.equal(authorize.searchParams.get("code_challenge_method"), "S256");
    assert.equal(authorize.searchParams.get("audience"), "fake-audience");
    assert.ok(authorize.searchParams.get("nonce"), "authorize URL must carry a nonce");

    const storePath = path.join(dir, "credentials.json");
    const mode = fs.statSync(storePath).mode & 0o777;
    assert.equal(mode, 0o600, "credentials must not be readable by others");

    const status = await runCli(["status"], baseEnv);
    const parsed = JSON.parse(status.stdout);
    assert.equal(parsed.signedIn, true);
    assert.equal(parsed.subject, "sub-test");
    assert.deepEqual(parsed.tenant, { organizationId: "org-test", workspaceId: "ws-test" });
    assert.ok(parsed.bearerExpiresInSeconds > 3000);

    const token = await runCli(["token"], baseEnv);
    assert.equal(token.code, 0);
    assert.match(token.stdout.trim(), /^[\w-]+\.[\w-]+\.sig-\d+$/);

    const org = await runCli(["header", "organization"], baseEnv);
    assert.equal(org.stdout.trim(), "org-test");
    const workspace = await runCli(["header", "x-external-workspace-id"], baseEnv);
    assert.equal(workspace.stdout.trim(), "ws-test");
  });

  test("token prints a fresh bearer without touching the issuer", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 3600 });
    const before = fake.state.refreshCount;
    const token = await runCli(["token"], baseEnv);
    assert.equal(token.code, 0);
    assert.equal(fake.state.refreshCount, before, "a fresh bearer must not trigger a refresh");
    assert.match(token.stdout.trim(), /^[\w-]+\.[\w-]+\.sig-seed$/);
  });

  test("token refreshes an expired bearer and persists the rotated refresh token", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 10 });
    const token = await runCli(["token"], baseEnv);
    assert.equal(token.code, 0, `token failed: ${token.stderr}`);
    assert.equal(fake.state.refreshCount, 1);
    assert.match(token.stdout.trim(), /^[\w-]+\.[\w-]+\.sig-\d+$/);
    assert.doesNotMatch(token.stdout.trim(), /sig-seed/, "a refresh must replace the bearer");

    const stored = JSON.parse(fs.readFileSync(path.join(dir, "credentials.json"), "utf8"));
    assert.equal(stored.refresh_token, fake.state.refreshToken, "rotated refresh token must be stored");
    assert.notEqual(stored.refresh_token, "refresh-seed");
    assert.equal(stored.tenant.organization_id, "org-test", "tenant survives a refresh");
  });

  test("concurrent callers perform exactly one refresh", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 10 });
    const results = await Promise.all(
      Array.from({ length: 5 }, () => runCli(["token"], baseEnv)),
    );
    for (const result of results) assert.equal(result.code, 0, `a caller failed: ${result.stderr}`);
    const bearers = new Set(results.map((result) => result.stdout.trim()));
    assert.equal(bearers.size, 1, "every caller must print the same bearer");
    assert.equal(fake.state.refreshCount, 1, "the single-use refresh token must be consumed once");

    const leftoverLock = fs.existsSync(path.join(dir, "credentials.lock"));
    assert.equal(leftoverLock, false, "the lock must be released");
  });

  test("an unrefreshable sign-in asks for a new login instead of printing a stale bearer", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 10 });
    fake.state.refreshToken = "something-else";
    const token = await runCli(["token"], baseEnv);
    assert.equal(token.code, 3, "an expired sign-in must fail with a login hint");
    assert.equal(token.stdout, "", "no token may reach stdout");
    assert.match(token.stderr, /vibe-token login/);
  });

  test("status never prints a token", async () => {
    const dir = scenario();
    const store = writeExpiredStore(dir, fake.state, { lifetime: 3600 });
    const status = await runCli(["status"], baseEnv);
    assert.equal(status.code, 0);
    assert.ok(!status.stdout.includes(store.id_token), "status must not leak the ID token");
    assert.ok(!status.stdout.includes(store.access_token), "status must not leak the access token");
    assert.ok(!status.stdout.includes(store.refresh_token), "status must not leak the refresh token");
  });

  test("a sign-out that lands while the browser is open is not undone by login", async () => {
    const dir = scenario();
    const port = await freePort();
    const result = await loginWithFakeBrowser(baseEnv, port, fake.state, async () => {
      const logout = await runCli(["logout"], baseEnv);
      assert.equal(logout.code, 0);
    });

    assert.equal(result.code, 3, `login must honour the sign-out: ${result.stderr}`);
    assert.match(result.stderr, /sign-out happened while you were signing in/);
    assert.equal(fs.existsSync(path.join(dir, "credentials.json")), false);
    const token = await runCli(["token"], baseEnv);
    assert.equal(token.code, 3, "no bearer may be printed after a sign-out");
  });

  test("extra arguments are refused instead of ignored", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 3600 });

    const token = await runCli(["token", "--help"], baseEnv);
    assert.equal(token.code, 2, "`token --help` must not be treated as `token`");
    assert.equal(token.stdout, "", "no bearer may be printed for an unexpected argument");
    assert.match(token.stderr, /takes no arguments/);

    const logout = await runCli(["logout", "--help"], baseEnv);
    assert.equal(logout.code, 2, "`logout --help` must not delete credentials");
    assert.equal(fs.existsSync(path.join(dir, "credentials.json")), true);

    const header = await runCli(["header"], baseEnv);
    assert.equal(header.code, 2, "`header` needs a field");
  });

  test("a sign-out during workspace discovery is not reported as a successful sign-in", async () => {
    const dir = scenario();
    const port = await freePort();
    fake.state.onWorkspaces = () => fs.unlinkSync(path.join(dir, "credentials.json"));
    const result = await loginWithFakeBrowser(baseEnv, port, fake.state);

    assert.equal(result.code, 3, `login must fail when the store vanished: ${result.stderr}`);
    assert.match(result.stderr, /sign-out happened while you were signing in/);
    assert.ok(!/Signed in\./.test(result.stderr), "no success message may be printed");
    assert.equal(fs.existsSync(path.join(dir, "credentials.json")), false);
  });

  test("an empty lock is not stolen while it is fresh, and is reclaimed once stale", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 10 });
    const lockPath = path.join(dir, "credentials.lock");
    fs.writeFileSync(lockPath, "", { mode: 0o600 });

    const before = fake.state.refreshCount;
    const blocked = await runCli(["token"], { ...baseEnv, VIBE_TOKEN_LOCK_TIMEOUT_MS: "800" });
    assert.notEqual(blocked.code, 0, "a fresh unattributable lock must not be taken over");
    assert.equal(fake.state.refreshCount, before);

    // A writer that died between creating the lock and stamping it leaves this
    // behind; once clearly stale it must not wedge the tool forever.
    const ancient = new Date(Date.now() - 10 * 60 * 1000);
    fs.utimesSync(lockPath, ancient, ancient);
    const reclaimed = await runCli(["token"], { ...baseEnv, VIBE_TOKEN_LOCK_TIMEOUT_MS: "5000" });
    assert.equal(reclaimed.code, 0, `a stale empty lock must be reclaimed: ${reclaimed.stderr}`);
    assert.equal(fake.state.refreshCount, 1);
  });

  test("a lock held by a live process is never stolen, however old it looks", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 10 });
    const lockPath = path.join(dir, "credentials.lock");
    // A live owner (this test process) and a timestamp old enough to look stale.
    fs.writeFileSync(lockPath, `${process.pid}:held-by-test\n`, { mode: 0o600 });
    const ancient = new Date(Date.now() - 10 * 60 * 1000);
    fs.utimesSync(lockPath, ancient, ancient);

    const before = fake.state.refreshCount;
    const token = await runCli(["token"], {
      ...baseEnv,
      VIBE_TOKEN_LOCK_TIMEOUT_MS: "800",
    });

    assert.notEqual(token.code, 0, "a held lock must block the refresh");
    assert.match(token.stderr, /timed out waiting for/);
    assert.equal(fake.state.refreshCount, before, "no refresh may run without the lock");
    assert.match(
      fs.readFileSync(lockPath, "utf8"),
      /^\d+:held-by-test/,
      "the live owner's lock must survive",
    );
  });

  test("a lock abandoned by a dead process is reclaimed", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 10 });
    const lockPath = path.join(dir, "credentials.lock");
    // 4194303 is above the default pid_max, so no process can hold it.
    fs.writeFileSync(lockPath, "4194303:abandoned\n", { mode: 0o600 });

    const token = await runCli(["token"], { ...baseEnv, VIBE_TOKEN_LOCK_TIMEOUT_MS: "5000" });
    assert.equal(token.code, 0, `a dead owner's lock must be reclaimed: ${token.stderr}`);
    assert.equal(fake.state.refreshCount, 1);
    assert.equal(fs.existsSync(lockPath), false, "the reclaimed lock must be released");
  });

  test("a concurrent refresh does not undo logout", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state, { lifetime: 10 });
    await Promise.all([runCli(["token"], baseEnv), runCli(["logout"], baseEnv)]);

    const after = await runCli(["token"], baseEnv);
    assert.equal(after.code, 3, "logout must survive a refresh that ran at the same time");
    assert.equal(fs.existsSync(path.join(dir, "credentials.json")), false);
    assert.equal(fs.existsSync(path.join(dir, "credentials.lock")), false);
  });

  test("logout forgets the sign-in", async () => {
    const dir = scenario();
    writeExpiredStore(dir, fake.state);
    const logout = await runCli(["logout"], baseEnv);
    assert.equal(logout.code, 0);
    assert.equal(fs.existsSync(path.join(dir, "credentials.json")), false);

    const token = await runCli(["token"], baseEnv);
    assert.equal(token.code, 3);
    assert.match(token.stderr, /not signed in/);

    const status = await runCli(["status"], baseEnv);
    assert.deepEqual(JSON.parse(status.stdout), { signedIn: false });
  });

  test("workspace discovery is retried when the tenant is missing", async () => {
    const dir = scenario();
    const store = writeExpiredStore(dir, fake.state, { lifetime: 3600 });
    delete store.tenant;
    fs.writeFileSync(path.join(dir, "credentials.json"), JSON.stringify(store), { mode: 0o600 });

    const org = await runCli(["header", "organization"], baseEnv);
    assert.equal(org.code, 0, `header failed: ${org.stderr}`);
    assert.equal(org.stdout.trim(), "org-test");
    assert.match(fake.state.lastBearer || "", /^Bearer [\w-]+\.[\w-]+\.sig-seed$/);

    const stored = JSON.parse(fs.readFileSync(path.join(dir, "credentials.json"), "utf8"));
    assert.equal(stored.tenant.organization_id, "org-test", "discovered tenant must be persisted");
  });
});
