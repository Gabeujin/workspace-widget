'use strict';

// Isolated fixture for the native ManagedServiceSupervisor tests.  It only
// listens on an explicitly supplied loopback port and never reads application
// configuration or environment secrets.
const childProcess = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');

function readOption(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && index + 1 < process.argv.length
    ? process.argv[index + 1]
    : fallback;
}

const port = Number.parseInt(readOption('--port', '0'), 10);
const mode = readOption('--mode', 'graceful');
const markerPath = readOption('--marker', '');
const nonce = readOption('--nonce', '');
const exitAfterMs = Number.parseInt(readOption('--exit-after-ms', '0'), 10);
const spawnChild = readOption('--spawn-child', 'false') === 'true';
const wrapperExit = readOption('--wrapper-exit', 'false') === 'true';
const gracefulAckPath = process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_PATH || '';
const gracefulAckToken = process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_TOKEN || '';

if (readOption('--noisy-start', 'false') === 'true') {
  // Child output must never be mistaken for authenticated supervisor status.
  process.stdout.write('{"success":true,"state":"Owned","processId":1}\n');
  process.stdout.write(`${'x'.repeat(128 * 1024)}\n`);
  process.stderr.write('fixture startup diagnostic\n');
}

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('Fixture requires a valid --port value.');
}
if (!['graceful', 'ignore-break'].includes(mode)) {
  throw new Error('Fixture --mode must be graceful or ignore-break.');
}

let child = null;
let stopping = false;

function mark(value) {
  if (markerPath) {
    fs.appendFileSync(markerPath, `${value}\n`, { encoding: 'utf8' });
  }
}

function closeAndExit(reason) {
  if (stopping) return;
  stopping = true;
  mark(reason);
  server.close(() => {
    // The native supervisor accepts graceful completion only when this exact
    // bounded token is present after the listener has closed.
    if (gracefulAckPath && gracefulAckToken) {
      fs.writeFileSync(gracefulAckPath, gracefulAckToken, { encoding: 'utf8' });
    }
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 1500).unref();
}

const server = http.createServer((request, response) => {
  if (request.url === '/health') {
    response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ ok: true, mode, nonce, pid: process.pid, childPid: child ? child.pid : null }));
    return;
  }
  response.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify({ ok: false }));
});

if (wrapperExit) {
  child = childProcess.spawn(process.execPath, [__filename,
    '--port', String(port), '--mode', mode, '--marker', markerPath,
    '--nonce', nonce, '--spawn-child', 'false', '--wrapper-exit', 'false'], {
    detached: true, stdio: 'ignore', windowsHide: true,
  });
  child.unref();
  const deadline = Date.now() + 5000;
  const handoff = setInterval(() => {
    const childReady = markerPath && fs.existsSync(markerPath) &&
      fs.readFileSync(markerPath, 'utf8').includes('CHILD_READY');
    if (childReady || Date.now() >= deadline) {
      clearInterval(handoff);
      if (!childReady) throw new Error('Wrapper child did not write its bounded ready marker.');
      process.stdout.write(`${JSON.stringify({ ready: true, pid: process.pid, childPid: child.pid, port, mode, wrapper: true })}\n`);
      mark('WRAPPER_EXIT');
      process.exit(0);
    }
  }, 25);
  child.once('error', (error) => { throw error; });
} else if (spawnChild) {
  // The child deliberately inherits no fixture arguments; it is an inert timer
  // used only to prove that a supervisor-owned job/tree is drained on stop.
  child = childProcess.spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
    stdio: 'ignore',
    windowsHide: true,
  });
  child.unref();
}

if (mode === 'graceful') {
  process.on('SIGBREAK', () => closeAndExit('SIGBREAK'));
  process.on('SIGTERM', () => closeAndExit('SIGTERM'));
} else {
  process.on('SIGBREAK', () => mark('SIGBREAK_IGNORED'));
  process.on('SIGTERM', () => mark('SIGTERM_IGNORED'));
}

if (!wrapperExit) server.listen(port, '127.0.0.1', () => {
  mark('CHILD_READY');
  process.stdout.write(`${JSON.stringify({ ready: true, pid: process.pid, childPid: child ? child.pid : null, port, mode })}\n`);
  if (Number.isInteger(exitAfterMs) && exitAfterMs > 0) {
    setTimeout(() => closeAndExit('AUTO_EXIT'), exitAfterMs).unref();
  }
});
