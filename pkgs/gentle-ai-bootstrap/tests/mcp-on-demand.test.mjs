import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SHIM_PATH = path.resolve(__dirname, '..', 'mcp-on-demand.mjs');
const ECHO_SERVER_PATH = path.resolve(__dirname, 'fixtures', 'echo-server.mjs');

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(predicate, { timeoutMs = 8000, intervalMs = 25, message = 'condition timed out' } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await predicate();
    if (value) return value;
    await sleep(intervalMs);
  }
  throw new Error(message);
}

function readPidLines(filePath) {
  if (!fs.existsSync(filePath)) return [];
  return fs
    .readFileSync(filePath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => Number.parseInt(line, 10))
    .filter((n) => Number.isInteger(n) && n > 0);
}

describe('mcp-on-demand shim', () => {
  let tmpDir;
  let runtimeDir;
  let upstreamPidFile;
  /** @type {Set<number>} */
  let trackedPids;
  /** @type {Array<import('node:child_process').ChildProcess>} */
  let trackedChildren;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-on-demand-test-'));
    runtimeDir = path.join(tmpDir, 'runtime');
    fs.mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
    upstreamPidFile = path.join(tmpDir, 'upstream-pids.txt');
    trackedPids = new Set();
    trackedChildren = [];
  });

  afterEach(async () => {
    for (const child of trackedChildren) {
      if (child.pid) trackedPids.add(child.pid);
      try {
        child.stdin?.destroy();
      } catch {}
    }

    if (fs.existsSync(runtimeDir)) {
      for (const entry of fs.readdirSync(runtimeDir)) {
        if (entry.endsWith('.pid')) {
          const raw = fs.readFileSync(path.join(runtimeDir, entry), 'utf8').trim();
          const pid = Number.parseInt(raw, 10);
          if (Number.isInteger(pid) && pid > 0) trackedPids.add(pid);
        }
      }
    }

    for (const pid of readPidLines(upstreamPidFile)) {
      trackedPids.add(pid);
    }

    for (const pid of trackedPids) {
      if (pid !== process.pid && isPidAlive(pid)) {
        try {
          process.kill(pid, 'SIGKILL');
        } catch {}
      }
    }

    for (const pid of trackedPids) {
      if (pid !== process.pid && isPidAlive(pid)) {
        await waitFor(() => !isPidAlive(pid), { timeoutMs: 2000, intervalMs: 20 }).catch(() => {});
      }
    }

    if (tmpDir && fs.existsSync(tmpDir)) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  function startBridge({
    name = 'echo',
    extraShimArgs = [],
    envOverrides = {},
  } = {}) {
    const child = spawn(
      process.execPath,
      [SHIM_PATH, '--name', name, ...extraShimArgs, '--', process.execPath, ECHO_SERVER_PATH],
      {
        env: {
          ...process.env,
          MCP_ON_DEMAND_DIR: runtimeDir,
          ECHO_SERVER_PID_FILE: upstreamPidFile,
          ...envOverrides,
        },
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    );
    trackedChildren.push(child);
    if (child.pid) trackedPids.add(child.pid);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');

    let stdoutBuffer = '';
    let stderrText = '';
    /** @type {Array<any>} */
    const messages = [];
    /** @type {Array<(msg: any) => void>} */
    const waiters = [];

    child.stdout.on('data', (chunk) => {
      stdoutBuffer += chunk;
      let idx;
      while ((idx = stdoutBuffer.indexOf('\n')) !== -1) {
        const line = stdoutBuffer.slice(0, idx).replace(/\r$/, '');
        stdoutBuffer = stdoutBuffer.slice(idx + 1);
        if (!line.trim()) continue;
        const parsed = JSON.parse(line);
        const waiter = waiters.shift();
        if (waiter) {
          waiter(parsed);
        } else {
          messages.push(parsed);
        }
      }
    });

    child.stderr.on('data', (chunk) => {
      stderrText += chunk;
    });

    const exitPromise = new Promise((resolve) => {
      child.once('exit', (code, signal) => resolve({ code, signal }));
    });

    return {
      child,
      getStderr: () => stderrText,
      send(obj) {
        child.stdin.write(`${JSON.stringify(obj)}\n`);
      },
      async nextMessage(timeoutMs = 8000) {
        if (messages.length > 0) {
          return messages.shift();
        }
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            const i = waiters.indexOf(onMsg);
            if (i !== -1) waiters.splice(i, 1);
            reject(new Error(`Timed out waiting for bridge stdout JSON-RPC frame. stderr=${stderrText}`));
          }, timeoutMs);
          function onMsg(msg) {
            clearTimeout(timer);
            resolve(msg);
          }
          waiters.push(onMsg);
        });
      },
      async close(timeoutMs = 8000) {
        child.stdin.end();
        let timer = null;
        try {
          return await Promise.race([
            exitPromise,
            new Promise((_, reject) => {
              timer = setTimeout(() => {
                reject(new Error(`Bridge PID ${child.pid} did not exit within ${timeoutMs}ms after stdin closed`));
              }, timeoutMs);
            }),
          ]);
        } finally {
          if (timer !== null) clearTimeout(timer);
        }
      },
      exitPromise,
    };
  }

  function readDaemonPid(name = 'echo') {
    const pidFile = path.join(runtimeDir, `${name}.pid`);
    if (!fs.existsSync(pidFile)) return null;
    const pid = Number.parseInt(fs.readFileSync(pidFile, 'utf8').trim(), 10);
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  }

  it('1. routes two concurrent bridges with the same numeric id to their own responses using one upstream process', async () => {
    const b1 = startBridge({ name: 'pooled' });
    const b2 = startBridge({ name: 'pooled' });

    // Both bridges send initialize with the exact same numeric id = 1 concurrently.
    b1.send({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'c1', version: '1.0' } },
    });
    b2.send({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'c2', version: '1.0' } },
    });

    const [init1, init2] = await Promise.all([b1.nextMessage(), b2.nextMessage()]);
    assert.equal(init1.id, 1);
    assert.equal(typeof init1.id, 'number');
    assert.equal(init2.id, 1);
    assert.equal(typeof init2.id, 'number');
    assert.equal(init1.result.serverInfo.name, 'echo-server');
    assert.equal(init2.result.serverInfo.name, 'echo-server');
    assert.equal(init1.result.serverInfo.pid, init2.result.serverInfo.pid);

    const daemonPid = readDaemonPid('pooled');
    assert.ok(daemonPid && isPidAlive(daemonPid), 'daemon pid must be recorded and alive');
    trackedPids.add(daemonPid);

    // Client notifications without id must not be forwarded or produce stray replies.
    b1.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    b2.send({ jsonrpc: '2.0', method: 'notifications/initialized' });

    // Both bridges send tools/call with the SAME numeric id = 42 at the same time.
    // b1 is slower (80ms) than b2 (10ms) so upstream replies arrive out of order,
    // and b1 also asks upstream to emit an id-less notification first (which must be dropped).
    b1.send({
      jsonrpc: '2.0',
      id: 42,
      method: 'tools/call',
      params: { name: 'echo', arguments: { session: 'bridge-one', delayMs: 80, emitNotificationFirst: true } },
    });
    b2.send({
      jsonrpc: '2.0',
      id: 42,
      method: 'tools/call',
      params: { name: 'echo', arguments: { session: 'bridge-two', delayMs: 10 } },
    });

    const [call1, call2] = await Promise.all([b1.nextMessage(), b2.nextMessage()]);
    assert.equal(call1.id, 42);
    assert.equal(typeof call1.id, 'number');
    assert.equal(call2.id, 42);
    assert.equal(typeof call2.id, 'number');
    assert.equal(call1.result.args.session, 'bridge-one');
    assert.equal(call2.result.args.session, 'bridge-two');
    assert.equal(call1.result.pid, call2.result.pid);
    // Upstream saw namespaced ids (not raw 42), proving daemon rewrote and restored ids.
    assert.notEqual(call1.result.echoedId, 42);
    assert.notEqual(call2.result.echoedId, 42);
    assert.notEqual(call1.result.echoedId, call2.result.echoedId);

    // ping is answered locally with {}.
    b1.send({ jsonrpc: '2.0', id: 99, method: 'ping' });
    const pingReply = await b1.nextMessage();
    assert.deepEqual(pingReply, { jsonrpc: '2.0', id: 99, result: {} });

    const upstreamPids = readPidLines(upstreamPidFile);
    assert.equal(
      upstreamPids.length,
      1,
      `Expected exactly 1 upstream process, got ${upstreamPids.length}: ${upstreamPids.join(', ')}`,
    );

    await Promise.all([b1.close(), b2.close()]);
  });

  it('2. keeps the daemon alive when the first (spawning) bridge closes while the second stays attached', async () => {
    const b1 = startBridge({ name: 'survive', extraShimArgs: ['--idle-seconds', '1'] });
    b1.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    await b1.nextMessage();

    const daemonPid = readDaemonPid('survive');
    assert.ok(daemonPid && isPidAlive(daemonPid));
    trackedPids.add(daemonPid);

    const b2 = startBridge({ name: 'survive', extraShimArgs: ['--idle-seconds', '1'] });
    b2.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    await b2.nextMessage();

    // Close the bridge that originally spawned the daemon.
    const exit1 = await b1.close();
    assert.equal(exit1.code, 0);

    // Wait longer than the 1s idle timeout while b2 remains attached: daemon must NOT exit.
    await sleep(1300);
    assert.equal(isPidAlive(daemonPid), true, 'daemon died while second bridge was still attached');

    b2.send({
      jsonrpc: '2.0',
      id: 7,
      method: 'tools/call',
      params: { name: 'echo', arguments: { from: 'survivor' } },
    });
    const reply2 = await b2.nextMessage();
    assert.equal(reply2.id, 7);
    assert.equal(reply2.result.args.from, 'survivor');
    assert.equal(readPidLines(upstreamPidFile).length, 1);

    await b2.close();
  });

  it('3. cancels the idle timer on late attach and exits removing socket+pid after the last bridge leaves', async () => {
    const sockPath = path.join(runtimeDir, 'idlecheck.sock');
    const pidPath = path.join(runtimeDir, 'idlecheck.pid');

    const b1 = startBridge({
      name: 'idlecheck',
      envOverrides: { MCP_ON_DEMAND_IDLE_SECONDS: '1' },
    });
    b1.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    await b1.nextMessage();

    const daemonPid = readDaemonPid('idlecheck');
    assert.ok(daemonPid && isPidAlive(daemonPid));
    trackedPids.add(daemonPid);

    await b1.close();

    // Re-attach at 350ms (before the 1s idle timer fires).
    await sleep(350);
    const b2 = startBridge({
      name: 'idlecheck',
      envOverrides: { MCP_ON_DEMAND_IDLE_SECONDS: '1' },
    });
    b2.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    await b2.nextMessage();

    // Stay past the original 1s deadline (350ms + 900ms = 1250ms > 1000ms).
    await sleep(900);
    assert.equal(isPidAlive(daemonPid), true, 'late attach failed to cancel the idle timer');
    assert.equal(readDaemonPid('idlecheck'), daemonPid);

    b2.send({
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: 'echo', arguments: { check: 'still-same-daemon' } },
    });
    const reply = await b2.nextMessage();
    assert.equal(reply.id, 2);
    assert.equal(reply.result.args.check, 'still-same-daemon');
    assert.equal(readPidLines(upstreamPidFile).length, 1);

    // Now detach the last bridge and verify idle exit cleans up process + socket + pid.
    await b2.close();
    await waitFor(
      () => !isPidAlive(daemonPid) && !fs.existsSync(sockPath) && !fs.existsSync(pidPath),
      {
        timeoutMs: 4000,
        intervalMs: 40,
        message: 'daemon did not exit and remove socket+pid after idle period',
      },
    );
  });

  it('4. terminates the daemon and cleans up socket+pid via --stop', async () => {
    const sockPath = path.join(runtimeDir, 'stoppable.sock');
    const pidPath = path.join(runtimeDir, 'stoppable.pid');

    const b1 = startBridge({ name: 'stoppable' });
    b1.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    await b1.nextMessage();

    const daemonPid = readDaemonPid('stoppable');
    assert.ok(daemonPid && isPidAlive(daemonPid));
    trackedPids.add(daemonPid);
    const [upstreamPid] = readPidLines(upstreamPidFile);
    assert.ok(upstreamPid && isPidAlive(upstreamPid));

    await b1.close();
    assert.equal(isPidAlive(daemonPid), true);

    const stopProc = spawn(
      process.execPath,
      [SHIM_PATH, '--name', 'stoppable', '--stop'],
      {
        env: { ...process.env, MCP_ON_DEMAND_DIR: runtimeDir },
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    trackedChildren.push(stopProc);

    const stopExit = await new Promise((resolve) => {
      stopProc.once('exit', (code, signal) => resolve({ code, signal }));
    });
    assert.equal(stopExit.code, 0);
    assert.equal(isPidAlive(daemonPid), false, 'daemon should be gone when --stop returns');
    await waitFor(() => !isPidAlive(upstreamPid), {
      timeoutMs: 3000,
      message: 'upstream process did not exit after --stop',
    });
    assert.equal(fs.existsSync(sockPath), false);
    assert.equal(fs.existsSync(pidPath), false);
  });

  it('5. ignores SIGHUP sent to the daemon PID and continues serving existing and new bridges', async () => {
    const b1 = startBridge({ name: 'sighup-safe' });
    b1.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    await b1.nextMessage();

    const daemonPid = readDaemonPid('sighup-safe');
    assert.ok(daemonPid && isPidAlive(daemonPid));
    trackedPids.add(daemonPid);

    process.kill(daemonPid, 'SIGHUP');
    await sleep(250);
    assert.equal(isPidAlive(daemonPid), true, 'daemon died on SIGHUP');

    const b2 = startBridge({ name: 'sighup-safe' });
    b2.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    const init2 = await b2.nextMessage();
    assert.equal(init2.id, 1);

    b2.send({
      jsonrpc: '2.0',
      id: 5,
      method: 'tools/call',
      params: { name: 'echo', arguments: { afterSighup: true } },
    });
    const call2 = await b2.nextMessage();
    assert.equal(call2.id, 5);
    assert.equal(call2.result.args.afterSighup, true);
    assert.equal(readPidLines(upstreamPidFile).length, 1);

    await Promise.all([b1.close(), b2.close()]);
  });

  it('6. recovers from a stale socket file left by a dead listener', async () => {
    const sockPath = path.join(runtimeDir, 'stale.sock');

    // Create a genuine stale Unix socket by SIGKILLing a temporary listener process.
    const holder = spawn(
      process.execPath,
      [
        '-e',
        `
          const net = require("node:net");
          const srv = net.createServer();
          srv.listen(process.argv[1], () => {
            process.stdout.write("READY\\n");
          });
        `,
        sockPath,
      ],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
    trackedChildren.push(holder);
    if (holder.pid) trackedPids.add(holder.pid);

    await new Promise((resolve, reject) => {
      holder.stdout.setEncoding('utf8');
      holder.stdout.on('data', (d) => {
        if (d.includes('READY')) resolve();
      });
      holder.once('exit', (code) => reject(new Error(`holder exited prematurely: ${code}`)));
    });

    process.kill(holder.pid, 'SIGKILL');
    await waitFor(() => !isPidAlive(holder.pid), { timeoutMs: 2000 });
    assert.equal(fs.lstatSync(sockPath).isSocket(), true, 'stale socket file must exist before recovery');

    const b1 = startBridge({ name: 'stale' });
    b1.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    const init = await b1.nextMessage();
    assert.equal(init.id, 1);
    assert.equal(init.result.serverInfo.name, 'echo-server');

    const daemonPid = readDaemonPid('stale');
    assert.ok(daemonPid && isPidAlive(daemonPid));
    trackedPids.add(daemonPid);

    b1.send({
      jsonrpc: '2.0',
      id: 9,
      method: 'tools/call',
      params: { name: 'echo', arguments: { recovered: true } },
    });
    const call = await b1.nextMessage();
    assert.equal(call.id, 9);
    assert.equal(call.result.args.recovered, true);

    await b1.close();
  });

  it('7. drains in-flight responses on half-close and refuses invalid --name values', async () => {
    // Refuse unsafe --name before creating sockets or writing anything to stdout.
    for (const badName of ['../escape', 'bad/name', 'bad.name', 'bad space', '']) {
      const proc = spawn(
        process.execPath,
        [SHIM_PATH, '--name', badName, '--', process.execPath, ECHO_SERVER_PATH],
        {
          env: { ...process.env, MCP_ON_DEMAND_DIR: runtimeDir },
          stdio: ['ignore', 'pipe', 'pipe'],
        },
      );
      trackedChildren.push(proc);
      let out = '';
      let errOut = '';
      proc.stdout.setEncoding('utf8');
      proc.stderr.setEncoding('utf8');
      proc.stdout.on('data', (c) => {
        out += c;
      });
      proc.stderr.on('data', (c) => {
        errOut += c;
      });
      const res = await new Promise((resolve) => proc.once('exit', (code) => resolve(code)));
      assert.notEqual(res, 0, `bad name "${badName}" should fail`);
      assert.equal(out, '', 'bridge must never write errors to stdout');
      assert.match(errOut, /--name/, 'stderr should explain invalid --name');
    }

    // Half-close: write initialize + slow tools/call and immediately end stdin.
    const b = startBridge({ name: 'halfclose' });
    b.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    b.send({
      jsonrpc: '2.0',
      id: 'str-id-2',
      method: 'tools/call',
      params: { name: 'echo', arguments: { delayMs: 80, halfClosed: true } },
    });
    const closePromise = b.close();

    const r1 = await b.nextMessage();
    const r2 = await b.nextMessage();
    const exit = await closePromise;

    assert.equal(exit.code, 0);
    assert.equal(r1.id, 1);
    assert.equal(r2.id, 'str-id-2');
    assert.equal(typeof r2.id, 'string');
    assert.equal(r2.result.args.halfClosed, true);

    const daemonPid = readDaemonPid('halfclose');
    if (daemonPid) trackedPids.add(daemonPid);
  });

  it('8. re-attaches automatically if the daemon drops while bridge stdin is still open', async () => {
    const b1 = startBridge({ name: 'reattach' });
    b1.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    const init1 = await b1.nextMessage();
    assert.equal(init1.id, 1);

    const firstDaemonPid = readDaemonPid('reattach');
    assert.ok(firstDaemonPid && isPidAlive(firstDaemonPid));
    trackedPids.add(firstDaemonPid);

    // Stop the daemon while b1's stdin is still open.
    const stopProc = spawn(
      process.execPath,
      [SHIM_PATH, '--name', 'reattach', '--stop'],
      {
        env: { ...process.env, MCP_ON_DEMAND_DIR: runtimeDir },
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    trackedChildren.push(stopProc);
    await new Promise((resolve) => stopProc.once('exit', resolve));
    assert.equal(isPidAlive(firstDaemonPid), false);

    // Bridge must stay alive because stdin is still open, re-attach to a fresh daemon,
    // and serve subsequent requests seamlessly.
    b1.send({
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: 'echo', arguments: { afterRestart: true } },
    });
    const callReply = await b1.nextMessage();
    assert.equal(callReply.id, 2);
    assert.equal(callReply.result.args.afterRestart, true);

    const secondDaemonPid = readDaemonPid('reattach');
    assert.ok(secondDaemonPid && isPidAlive(secondDaemonPid));
    assert.notEqual(secondDaemonPid, firstDaemonPid);
    trackedPids.add(secondDaemonPid);

    await b1.close();
  });
});
