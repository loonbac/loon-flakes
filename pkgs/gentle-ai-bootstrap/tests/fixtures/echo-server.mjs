#!/usr/bin/env node
import fs from 'node:fs';

const pidFile = process.env.ECHO_SERVER_PID_FILE;
if (pidFile) {
  fs.appendFileSync(pidFile, `${process.pid}\n`, 'utf8');
}

process.stdin.setEncoding('utf8');

let buffer = '';
let pending = 0;
let stdinEnded = false;

function maybeExit() {
  if (stdinEnded && pending === 0) {
    process.exit(0);
  }
}

function send(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function handleMessage(msg) {
  if (!msg || typeof msg !== 'object') return;
  if (!Object.prototype.hasOwnProperty.call(msg, 'id') || msg.id === null || msg.id === undefined) {
    // JSON-RPC notification (e.g. notifications/initialized) — no response.
    return;
  }

  const { id, method, params } = msg;

  switch (method) {
    case 'initialize':
      send({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: {
            name: 'echo-server',
            version: '1.0.0',
            pid: process.pid,
          },
        },
      });
      return;

    case 'ping':
      send({
        jsonrpc: '2.0',
        id,
        result: {
          echoedId: id,
          pid: process.pid,
        },
      });
      return;

    case 'tools/list':
      send({
        jsonrpc: '2.0',
        id,
        result: {
          tools: [
            {
              name: 'echo',
              description: 'Echoes arguments and upstream PID',
              inputSchema: { type: 'object' },
            },
          ],
          echoedId: id,
          pid: process.pid,
        },
      });
      return;

    case 'tools/call': {
      const args = params?.arguments ?? {};
      const delayMs = Number(args.delayMs ?? 0);
      if (args.emitNotificationFirst) {
        send({
          jsonrpc: '2.0',
          method: 'notifications/message',
          params: { level: 'info', data: 'upstream-notification' },
        });
      }
      const respond = () => {
        send({
          jsonrpc: '2.0',
          id,
          result: {
            content: [
              {
                type: 'text',
                text: JSON.stringify({
                  echoedId: id,
                  args,
                  pid: process.pid,
                }),
              },
            ],
            echoedId: id,
            args,
            pid: process.pid,
          },
        });
      };
      if (delayMs > 0) {
        pending += 1;
        setTimeout(() => {
          respond();
          pending -= 1;
          maybeExit();
        }, delayMs);
      } else {
        respond();
      }
      return;
    }

    default:
      send({
        jsonrpc: '2.0',
        id,
        error: {
          code: -32601,
          message: `Method not found: ${String(method)}`,
        },
      });
  }
}

process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let newlineIdx;
  while ((newlineIdx = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, newlineIdx).replace(/\r$/, '');
    buffer = buffer.slice(newlineIdx + 1);
    if (!line.trim()) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    handleMessage(parsed);
  }
});

process.stdin.on('end', () => {
  stdinEnded = true;
  maybeExit();
});
