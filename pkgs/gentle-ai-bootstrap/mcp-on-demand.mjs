#!/usr/bin/env node
/**
 * mcp-on-demand.mjs — Per-server on-demand stdio MCP pooling shim.
 *
 * Architecture:
 *   Pi spawns one bridge process per session per MCP server:
 *     node mcp-on-demand.mjs --name <name> [--idle-seconds N] -- <command> [args...]
 *
 *   The first bridge that finds no live socket spawns a detached per-server daemon:
 *     node mcp-on-demand.mjs --name <name> --daemon [--idle-seconds N] -- <command> [args...]
 *
 *   Each daemon owns at most ONE upstream stdio MCP child process and listens on
 *   `<dir>/<name>.sock` (with `<name>.pid` and `<name>.log` beside it), where:
 *     dir = $MCP_ON_DEMAND_DIR || ($XDG_RUNTIME_DIR || os.tmpdir()) + '/mcp-on-demand-' + process.getuid()
 *
 *   The daemon sends one `initialize` handshake to the upstream at startup, caches the
 *   `result` (`serverInfo`, `capabilities`, `protocolVersion`, etc.), answers client
 *   `initialize` and `ping` requests locally, drops client notifications without an `id`,
 *   and multiplexes all other JSON-RPC requests with an `id` by rewriting `id` to a
 *   connection-namespaced key (`"<connId>:<originalId>"`) and routing each response back
 *   exclusively to its originating connection with the original `id` (type + value) restored.
 *
 *   Daemon liveness follows the number of attached bridge connections (`attached`),
 *   saturating at zero and exiting after `MCP_ON_DEMAND_IDLE_SECONDS` (default 300s)
 *   once the last session detaches. `--stop` terminates a running daemon by PID:
 *     node mcp-on-demand.mjs --name <name> --stop
 *
 * Declared protocol limitation:
 *   Upstream server-initiated notifications without an `id` (including `notifications/message`
 *   logging, `notifications/progress`, and `notifications/*\/list_changed`) are NOT fanned out
 *   to attached bridges in this slice and are dropped by the daemon.
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const SHIM_PATH = fileURLToPath(import.meta.url);
const NAME_PATTERN = /^[A-Za-z0-9_-]+$/;
const DEFAULT_IDLE_SECONDS = 300;
const SPAWN_WAIT_MS = 10_000;
const CONNECT_RETRY_MS = 30;
const REATTACH_DELAY_MS = 100;
const HALF_CLOSE_DRAIN_MS = 5_000;
const STOP_WAIT_MS = 5_000;
const UPSTREAM_INIT_TIMEOUT_MS = 60_000;
const UPSTREAM_GRACE_MS = 500;
const DAEMON_INIT_ID = '0:daemon-init';

function waitWithTimeout(promise, ms) {
  let timer = null;
  return Promise.race([
    promise.then(
      (val) => {
        if (timer !== null) clearTimeout(timer);
        return { timedOut: false, value: val };
      },
      (err) => {
        if (timer !== null) clearTimeout(timer);
        throw err;
      },
    ),
    new Promise((resolve) => {
      timer = setTimeout(() => resolve({ timedOut: true, value: undefined }), ms);
    }),
  ]);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function failCli(message) {
  process.stderr.write(`mcp-on-demand: ${message}\n`);
  process.exit(2);
}

function parseCli(argv) {
  const dashDash = argv.indexOf('--');
  const shimArgs = dashDash === -1 ? argv : argv.slice(0, dashDash);
  const upstream = dashDash === -1 ? [] : argv.slice(dashDash + 1);

  let name = null;
  let mode = 'bridge';
  let sawDaemon = false;
  let sawStop = false;
  let explicitIdleSeconds = null;

  for (let i = 0; i < shimArgs.length; i += 1) {
    const arg = shimArgs[i];
    if (arg === '--name') {
      if (i + 1 >= shimArgs.length) failCli('missing value for --name');
      name = shimArgs[++i];
    } else if (arg.startsWith('--name=')) {
      name = arg.slice('--name='.length);
    } else if (arg === '--idle-seconds') {
      if (i + 1 >= shimArgs.length) failCli('missing value for --idle-seconds');
      const raw = shimArgs[++i];
      const parsed = Number(raw);
      if (!raw.trim() || !Number.isFinite(parsed) || parsed < 0) {
        failCli(`invalid --idle-seconds value: ${raw}`);
      }
      explicitIdleSeconds = parsed;
    } else if (arg.startsWith('--idle-seconds=')) {
      const raw = arg.slice('--idle-seconds='.length);
      const parsed = Number(raw);
      if (!raw.trim() || !Number.isFinite(parsed) || parsed < 0) {
        failCli(`invalid --idle-seconds value: ${raw}`);
      }
      explicitIdleSeconds = parsed;
    } else if (arg === '--daemon') {
      sawDaemon = true;
      mode = 'daemon';
    } else if (arg === '--stop') {
      sawStop = true;
      mode = 'stop';
    } else {
      failCli(`unknown option: ${arg}`);
    }
  }

  if (sawDaemon && sawStop) {
    failCli('--daemon and --stop cannot be combined');
  }

  if (typeof name !== 'string' || !NAME_PATTERN.test(name)) {
    failCli(`invalid or missing --name "${name ?? ''}" (must match [A-Za-z0-9_-]+)`);
  }

  if (mode === 'stop') {
    if (dashDash !== -1 || upstream.length > 0) {
      failCli('--stop does not accept an upstream command');
    }
  } else if (dashDash === -1 || upstream.length === 0 || !upstream[0]) {
    failCli('missing "-- <command> [args...]"');
  }

  let idleSeconds = DEFAULT_IDLE_SECONDS;
  if (explicitIdleSeconds !== null) {
    idleSeconds = explicitIdleSeconds;
  } else if (process.env.MCP_ON_DEMAND_IDLE_SECONDS?.trim()) {
    const envIdle = Number(process.env.MCP_ON_DEMAND_IDLE_SECONDS.trim());
    if (Number.isFinite(envIdle) && envIdle >= 0) {
      idleSeconds = envIdle;
    }
  }

  return {
    name,
    mode,
    upstream,
    idleSeconds,
    explicitIdleSeconds,
  };
}

function resolveRuntimePaths(name) {
  const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
  const envDir = process.env.MCP_ON_DEMAND_DIR?.trim();
  const xdgDir = process.env.XDG_RUNTIME_DIR?.trim();
  const dir = envDir || path.join(xdgDir || os.tmpdir(), `mcp-on-demand-${uid}`);
  return {
    dir,
    sockPath: path.join(dir, `${name}.sock`),
    pidPath: path.join(dir, `${name}.pid`),
    logPath: path.join(dir, `${name}.log`),
  };
}

function tryLstatBigInt(targetPath) {
  try {
    return fs.lstatSync(targetPath, { bigint: true });
  } catch {
    return null;
  }
}

function safeUnlink(targetPath) {
  try {
    fs.unlinkSync(targetPath);
  } catch {}
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

function tryConnect(sockPath) {
  return new Promise((resolve) => {
    const sock = net.createConnection({ path: sockPath, allowHalfOpen: true });
    const onConnect = () => {
      sock.removeListener('error', onError);
      resolve({ sock, err: null });
    };
    const onError = (err) => {
      sock.removeListener('connect', onConnect);
      try {
        sock.destroy();
      } catch {}
      resolve({ sock: null, err });
    };
    sock.once('connect', onConnect);
    sock.once('error', onError);
  });
}

async function runStop(name, paths) {
  const { pidPath } = paths;
  let rawPid;
  try {
    rawPid = fs.readFileSync(pidPath, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      process.stdout.write(`no daemon running for ${name}\n`);
      return;
    }
    throw err;
  }

  const pid = Number.parseInt(rawPid.trim(), 10);
  if (!Number.isInteger(pid) || pid <= 0) {
    process.stderr.write(`mcp-on-demand(${name}): malformed pid file ${pidPath}\n`);
    process.exit(1);
  }

  if (!isPidAlive(pid)) {
    safeUnlink(pidPath);
    process.stdout.write(`no daemon running for ${name} (pid ${pid} is gone)\n`);
    return;
  }

  try {
    process.kill(pid, 'SIGTERM');
  } catch (err) {
    if (!err || err.code !== 'ESRCH') throw err;
  }

  const deadline = Date.now() + STOP_WAIT_MS;
  while (Date.now() < deadline) {
    if (!isPidAlive(pid)) break;
    await sleep(25);
  }

  if (isPidAlive(pid)) {
    process.stderr.write(`mcp-on-demand(${name}): daemon pid ${pid} did not exit within ${STOP_WAIT_MS}ms\n`);
    process.exit(1);
  }

  safeUnlink(pidPath);
  process.stdout.write(`stopped daemon ${name} (pid ${pid})\n`);
}

async function runBridge(opts, paths) {
  const { name, upstream, explicitIdleSeconds } = opts;
  const { dir, sockPath, logPath } = paths;
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });

  let stdinEnded = false;
  /** @type {Buffer[]} */
  const pendingWrites = [];
  /** @type {net.Socket | null} */
  let activeSock = null;
  /** @type {(() => void) | null} */
  let onStdinEndSession = null;

  process.stdin.on('data', (chunk) => {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (activeSock && !activeSock.destroyed && activeSock.writable) {
      if (!activeSock.write(buf)) {
        process.stdin.pause();
      }
    } else {
      pendingWrites.push(buf);
    }
  });

  process.stdin.on('end', () => {
    stdinEnded = true;
    if (onStdinEndSession) {
      onStdinEndSession();
    }
  });

  process.stdin.on('error', () => {
    stdinEnded = true;
    if (onStdinEndSession) {
      onStdinEndSession();
    }
  });

  const cleanBridgeExit = async (code = 0) => {
    if (activeSock && !activeSock.destroyed) {
      try {
        activeSock.destroy();
      } catch {}
    }
    if (process.stdout.writableLength > 0) {
      await new Promise((resolve) => process.stdout.once('drain', resolve));
    }
    process.exit(code);
  };

  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
      void cleanBridgeExit(0);
    });
  }

  function spawnDaemon() {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const logFd = fs.openSync(logPath, 'a', 0o600);
    try {
      const args = [SHIM_PATH, '--name', name];
      if (explicitIdleSeconds !== null) {
        args.push('--idle-seconds', String(explicitIdleSeconds));
      }
      args.push('--daemon', '--', ...upstream);
      const child = spawn(process.execPath, args, {
        detached: true,
        stdio: ['ignore', 'ignore', logFd],
      });
      child.unref();
    } finally {
      try {
        fs.closeSync(logFd);
      } catch {}
    }
  }

  async function connectOrSpawn() {
    let spawned = false;
    const deadline = Date.now() + SPAWN_WAIT_MS;

    while (true) {
      const beforeStat = tryLstatBigInt(sockPath);
      const { sock, err } = await tryConnect(sockPath);
      if (sock) {
        return sock;
      }

      if (err && err.code === 'ECONNREFUSED') {
        const afterStat = tryLstatBigInt(sockPath);
        if (
          beforeStat &&
          afterStat &&
          beforeStat.ino === afterStat.ino &&
          beforeStat.ctimeNs === afterStat.ctimeNs
        ) {
          safeUnlink(sockPath);
        } else if (!beforeStat && afterStat) {
          await sleep(CONNECT_RETRY_MS);
          continue;
        }
      }

      if (!spawned) {
        spawnDaemon();
        spawned = true;
      } else if (Date.now() >= deadline) {
        process.stderr.write(
          `mcp-on-demand(${name}): daemon failed to listen on ${sockPath} within ${SPAWN_WAIT_MS}ms (see ${logPath})\n`,
        );
        await cleanBridgeExit(1);
      }

      await sleep(CONNECT_RETRY_MS);
    }
  }

  function pumpSession(sock) {
    return new Promise((resolve) => {
      activeSock = sock;
      let settled = false;
      let drainTimer = null;

      const finish = (outcome) => {
        if (settled) return;
        settled = true;
        if (drainTimer !== null) {
          clearTimeout(drainTimer);
          drainTimer = null;
        }
        if (activeSock === sock) {
          activeSock = null;
        }
        if (onStdinEndSession === startHalfCloseDrain) {
          onStdinEndSession = null;
        }
        sock.removeListener('drain', onSockDrain);
        process.stdout.removeListener('drain', onStdoutDrain);
        try {
          sock.destroy();
        } catch {}
        resolve(outcome);
      };

      const startHalfCloseDrain = () => {
        try {
          sock.end();
        } catch {}
        if (drainTimer === null) {
          drainTimer = setTimeout(() => finish('client_gone'), HALF_CLOSE_DRAIN_MS);
        }
      };

      onStdinEndSession = startHalfCloseDrain;

      const onSockDrain = () => {
        if (!stdinEnded) {
          process.stdin.resume();
        }
      };

      const onStdoutDrain = () => {
        if (!sock.destroyed) {
          sock.resume();
        }
      };

      sock.on('drain', onSockDrain);
      process.stdout.on('drain', onStdoutDrain);

      sock.on('data', (chunk) => {
        if (!process.stdout.write(chunk)) {
          sock.pause();
        }
      });

      sock.on('end', () => {
        finish(stdinEnded ? 'client_gone' : 'daemon_gone');
      });

      sock.on('close', () => {
        finish(stdinEnded ? 'client_gone' : 'daemon_gone');
      });

      sock.on('error', () => {
        finish(stdinEnded ? 'client_gone' : 'daemon_gone');
      });

      while (pendingWrites.length > 0) {
        const chunk = pendingWrites.shift();
        if (!sock.write(chunk)) {
          process.stdin.pause();
        }
      }

      if (stdinEnded) {
        startHalfCloseDrain();
      } else {
        process.stdin.resume();
      }
    });
  }

  while (true) {
    if (stdinEnded && pendingWrites.length === 0) {
      await cleanBridgeExit(0);
    }

    const sock = await connectOrSpawn();
    const outcome = await pumpSession(sock);
    if (outcome === 'client_gone' || stdinEnded) {
      await cleanBridgeExit(0);
    }

    await sleep(REATTACH_DELAY_MS);
  }
}

async function runDaemon(opts, paths) {
  const { name, upstream, idleSeconds } = opts;
  const { dir, sockPath, pidPath, logPath } = paths;

  for (const sig of ['SIGHUP', 'SIGTSTP', 'SIGTTIN']) {
    try {
      process.on(sig, () => {});
    } catch {}
  }

  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const logFd = fs.openSync(logPath, 'a', 0o600);
  const log = (msg) => {
    try {
      fs.writeSync(logFd, `[${new Date().toISOString()}] [daemon:${name}:${process.pid}] ${msg}\n`);
    } catch {}
  };

  let shuttingDown = false;
  let ownsSocket = false;
  let attached = 0;
  let nextConnId = 0;
  let requestSeq = 0;
  /** @type {NodeJS.Timeout | null} */
  let idleTimer = null;
  /** @type {Set<net.Socket>} */
  const activeSockets = new Set();
  /** @type {Map<string, { connId: number, originalId: string | number, connState: any }>} */
  const pendingRequests = new Map();

  /** @type {import('node:child_process').ChildProcess | null} */
  let upstreamProc = null;
  let upstreamExited = false;
  /** @type {Promise<void> | null} */
  let upstreamExitPromise = null;

  let resolveInit;
  let rejectInit;
  const initPromise = new Promise((resolve, reject) => {
    resolveInit = resolve;
    rejectInit = reject;
  });
  // Prevent unhandled rejection crashes when no client is currently awaiting initPromise.
  initPromise.catch(() => {});
  let initSettled = false;
  let cachedInitResult = null;

  function clearIdleTimer() {
    if (idleTimer !== null) {
      clearTimeout(idleTimer);
      idleTimer = null;
    }
  }

  function startIdleTimer() {
    clearIdleTimer();
    if (shuttingDown || attached > 0) return;
    idleTimer = setTimeout(() => {
      idleTimer = null;
      if (attached === 0 && !shuttingDown) {
        void shutdown('idle timeout');
      }
    }, Math.round(idleSeconds * 1000));
  }

  const server = net.createServer({ allowHalfOpen: true }, (socket) => {
    handleConnection(socket);
  });

  try {
    await new Promise((resolve, reject) => {
      const onError = (err) => {
        server.removeListener('listening', onListening);
        reject(err);
      };
      const onListening = () => {
        server.removeListener('error', onError);
        resolve();
      };
      server.once('error', onError);
      server.once('listening', onListening);
      server.listen(sockPath);
    });
  } catch (err) {
    if (err && err.code === 'EADDRINUSE') {
      log(`socket ${sockPath} already in use; exiting without unlinking`);
      try {
        fs.closeSync(logFd);
      } catch {}
      process.exit(0);
    }
    log(`failed to bind ${sockPath}: ${err?.message ?? err}`);
    try {
      fs.closeSync(logFd);
    } catch {}
    process.exit(1);
  }

  ownsSocket = true;
  try {
    fs.chmodSync(sockPath, 0o600);
  } catch {}
  fs.writeFileSync(pidPath, `${process.pid}\n`, { mode: 0o600 });
  log(`listening on ${sockPath} (idleSeconds=${idleSeconds})`);

  async function stopUpstream() {
    if (!upstreamProc || upstreamExited) return;
    try {
      upstreamProc.stdin?.end();
    } catch {}

    const afterEof = await waitWithTimeout(upstreamExitPromise, UPSTREAM_GRACE_MS);
    if (!afterEof.timedOut || upstreamExited) return;

    try {
      upstreamProc.kill('SIGTERM');
    } catch {}

    const afterTerm = await waitWithTimeout(upstreamExitPromise, UPSTREAM_GRACE_MS);
    if (!afterTerm.timedOut || upstreamExited) return;

    try {
      upstreamProc.kill('SIGKILL');
    } catch {}
    await waitWithTimeout(upstreamExitPromise, 100);
  }

  async function shutdown(reason, exitCode = 0) {
    if (shuttingDown) return;
    shuttingDown = true;
    clearIdleTimer();
    log(`shutting down: ${reason}`);

    if (ownsSocket) {
      safeUnlink(sockPath);
      safeUnlink(pidPath);
      ownsSocket = false;
    }

    const serverClosed = new Promise((resolve) => {
      try {
        server.close(() => resolve());
      } catch {
        resolve();
      }
    });

    for (const sock of activeSockets) {
      try {
        sock.destroy();
      } catch {}
    }
    activeSockets.clear();

    await serverClosed;

    await stopUpstream();
    try {
      fs.closeSync(logFd);
    } catch {}
    process.exit(exitCode);
  }

  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
      void shutdown(`received ${sig}`, 0);
    });
  }

  server.on('error', (err) => {
    log(`server error: ${err?.message ?? err}`);
  });

  // Spawn the single upstream MCP server process.
  try {
    upstreamProc = spawn(upstream[0], upstream.slice(1), {
      stdio: ['pipe', 'pipe', logFd],
    });
  } catch (err) {
    log(`failed to spawn upstream "${upstream[0]}": ${err?.message ?? err}`);
    await shutdown('upstream spawn failed', 1);
    return;
  }

  upstreamExitPromise = new Promise((resolve) => {
    upstreamProc.once('exit', (code, signal) => {
      upstreamExited = true;
      resolve({ code, signal });
      if (!initSettled) {
        initSettled = true;
        rejectInit(new Error(`upstream exited before initialize completed (code=${code}, signal=${signal})`));
      }
      if (!shuttingDown) {
        log(`upstream exited unexpectedly (code=${code}, signal=${signal})`);
        void shutdown('upstream exited', 1);
      }
    });
    upstreamProc.once('error', (err) => {
      upstreamExited = true;
      resolve({ code: null, signal: null });
      if (!initSettled) {
        initSettled = true;
        rejectInit(err);
      }
      if (!shuttingDown) {
        log(`upstream process error: ${err?.message ?? err}`);
        void shutdown('upstream error', 1);
      }
    });
  });

  upstreamProc.stdin.on('error', (err) => {
    log(`upstream stdin error: ${err?.message ?? err}`);
  });

  upstreamProc.stdout.setEncoding('utf8');
  let upstreamBuffer = '';

  const initTimer = setTimeout(() => {
    if (!initSettled) {
      initSettled = true;
      const err = new Error(`upstream did not answer initialize within ${UPSTREAM_INIT_TIMEOUT_MS}ms`);
      rejectInit(err);
      log(err.message);
      void shutdown('upstream initialize timeout', 1);
    }
  }, UPSTREAM_INIT_TIMEOUT_MS);
  initTimer.unref?.();

  upstreamProc.stdout.on('data', (chunk) => {
    upstreamBuffer += chunk;
    let newlineIdx;
    while ((newlineIdx = upstreamBuffer.indexOf('\n')) !== -1) {
      const line = upstreamBuffer.slice(0, newlineIdx).replace(/\r$/, '');
      upstreamBuffer = upstreamBuffer.slice(newlineIdx + 1);
      if (!line.trim()) continue;
      handleUpstreamLine(line);
    }
  });

  function writeToUpstream(payload) {
    if (!upstreamProc || upstreamExited || !upstreamProc.stdin?.writable) {
      return false;
    }
    upstreamProc.stdin.write(`${JSON.stringify(payload)}\n`);
    return true;
  }

  function handleUpstreamLine(line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      log(`ignoring non-JSON upstream stdout line: ${line.slice(0, 200)}`);
      return;
    }
    if (!msg || typeof msg !== 'object') return;

    const hasId = Object.prototype.hasOwnProperty.call(msg, 'id') && msg.id !== null && msg.id !== undefined;
    if (!hasId) {
      // Declared limitation: drop upstream notifications without an id.
      return;
    }

    if (msg.id === DAEMON_INIT_ID && !initSettled) {
      clearTimeout(initTimer);
      initSettled = true;
      if (msg.error) {
        const err = new Error(`upstream initialize returned error: ${JSON.stringify(msg.error)}`);
        rejectInit(err);
        log(err.message);
        void shutdown('upstream initialize error', 1);
        return;
      }
      cachedInitResult = msg.result ?? {};
      writeToUpstream({ jsonrpc: '2.0', method: 'notifications/initialized' });
      resolveInit(cachedInitResult);
      return;
    }

    // If upstream sends a server-initiated request (has both method and id), reply -32601 so it never hangs.
    if (typeof msg.method === 'string') {
      writeToUpstream({
        jsonrpc: '2.0',
        id: msg.id,
        error: {
          code: -32601,
          message: `Server-initiated request "${msg.method}" is not supported by mcp-on-demand`,
        },
      });
      return;
    }

    const key = String(msg.id);
    const entry = pendingRequests.get(key);
    if (!entry) {
      return;
    }
    pendingRequests.delete(key);

    const { originalId, connState } = entry;
    connState.inFlight = Math.max(0, connState.inFlight - 1);
    msg.id = originalId;

    if (!connState.closed && !connState.socket.destroyed && connState.socket.writable) {
      connState.socket.write(`${JSON.stringify(msg)}\n`);
    }

    if (connState.clientEnded && connState.inFlight === 0 && !connState.closed) {
      try {
        connState.socket.end();
      } catch {}
    }
  }

  // Send the single startup initialize request to upstream.
  writeToUpstream({
    jsonrpc: '2.0',
    id: DAEMON_INIT_ID,
    method: 'initialize',
    params: {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: {
        name: 'mcp-on-demand',
        version: '1.0.0',
      },
    },
  });

  startIdleTimer();

  function writeToClient(connState, payload) {
    if (!connState.closed && !connState.socket.destroyed && connState.socket.writable) {
      connState.socket.write(`${JSON.stringify(payload)}\n`);
    }
  }

  async function handleClientLine(connState, line) {
    if (connState.closed || shuttingDown) return;

    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      log(`conn ${connState.connId}: invalid JSON line`);
      return;
    }
    if (!msg || typeof msg !== 'object') return;

    const hasId = Object.prototype.hasOwnProperty.call(msg, 'id') && msg.id !== null && msg.id !== undefined;
    if (!hasId) {
      // Client notifications (notifications/initialized, etc.) without an id are not forwarded.
      return;
    }

    const originalId = msg.id;

    if (msg.method === 'ping') {
      writeToClient(connState, {
        jsonrpc: '2.0',
        id: originalId,
        result: {},
      });
      return;
    }

    if (msg.method === 'initialize') {
      const result = await initPromise;
      if (connState.closed) return;
      writeToClient(connState, {
        jsonrpc: '2.0',
        id: originalId,
        result,
      });
      return;
    }

    await initPromise;
    if (connState.closed || shuttingDown) return;

    const baseKey = `${connState.connId}:${String(originalId)}`;
    const namespacedId = pendingRequests.has(baseKey) ? `${baseKey}#${++requestSeq}` : baseKey;

    connState.inFlight += 1;
    pendingRequests.set(namespacedId, {
      connId: connState.connId,
      originalId,
      connState,
    });

    const forwarded = { ...msg, id: namespacedId };
    if (!writeToUpstream(forwarded)) {
      pendingRequests.delete(namespacedId);
      connState.inFlight = Math.max(0, connState.inFlight - 1);
      writeToClient(connState, {
        jsonrpc: '2.0',
        id: originalId,
        error: {
          code: -32603,
          message: `Upstream MCP server "${name}" is not available`,
        },
      });
    }
  }

  function handleConnection(socket) {
    if (shuttingDown) {
      try {
        socket.destroy();
      } catch {}
      return;
    }

    clearIdleTimer();
    const connId = ++nextConnId;
    attached += 1;
    activeSockets.add(socket);
    log(`conn ${connId} attached (attached=${attached})`);

    const connState = {
      connId,
      socket,
      inFlight: 0,
      clientEnded: false,
      closed: false,
    };

    socket.setEncoding('utf8');
    let lineBuf = '';
    let connQueue = Promise.resolve();
    let detached = false;

    const onDetach = () => {
      if (detached) return;
      detached = true;
      connState.closed = true;
      activeSockets.delete(socket);
      for (const [key, entry] of pendingRequests) {
        if (entry.connId === connId) {
          pendingRequests.delete(key);
        }
      }
      attached = Math.max(0, attached - 1);
      log(`conn ${connId} detached (attached=${attached})`);
      if (attached === 0 && !shuttingDown) {
        startIdleTimer();
      }
    };

    socket.on('data', (chunk) => {
      lineBuf += chunk;
      let idx;
      while ((idx = lineBuf.indexOf('\n')) !== -1) {
        const line = lineBuf.slice(0, idx).replace(/\r$/, '');
        lineBuf = lineBuf.slice(idx + 1);
        if (!line.trim()) continue;
        connQueue = connQueue
          .then(() => handleClientLine(connState, line))
          .catch((err) => {
            log(`conn ${connId} request failed: ${err?.message ?? err}`);
          });
      }
    });

    socket.on('end', () => {
      const trailing = lineBuf.replace(/\r$/, '').trim();
      lineBuf = '';
      if (trailing) {
        connQueue = connQueue
          .then(() => handleClientLine(connState, trailing))
          .catch((err) => {
            log(`conn ${connId} trailing request failed: ${err?.message ?? err}`);
          });
      }
      connQueue = connQueue.then(() => {
        connState.clientEnded = true;
        if (connState.inFlight === 0 && !connState.closed) {
          try {
            socket.end();
          } catch {}
        }
      });
    });

    socket.on('error', (err) => {
      log(`conn ${connId} socket error: ${err?.message ?? err}`);
    });

    socket.on('close', onDetach);
  }
}

async function main() {
  const opts = parseCli(process.argv.slice(2));
  const paths = resolveRuntimePaths(opts.name);

  if (opts.mode === 'stop') {
    await runStop(opts.name, paths);
    return;
  }
  if (opts.mode === 'daemon') {
    await runDaemon(opts, paths);
    return;
  }
  await runBridge(opts, paths);
}

main().catch((err) => {
  process.stderr.write(`mcp-on-demand fatal: ${err?.stack ?? err?.message ?? err}\n`);
  process.exit(1);
});
