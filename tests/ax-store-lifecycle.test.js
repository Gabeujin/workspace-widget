'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const broker = require('../app/ax-store-lifecycle-broker');

function fixture() {
  const root = path.join(os.tmpdir(), `WorkspaceWidgetAxLifecycle-${crypto.randomUUID()}`);
  fs.mkdirSync(root, { recursive: true });
  const secret = crypto.randomBytes(32);
  const secretPath = path.join(root, 'capability.key');
  const launcherPath = path.join(root, 'workspace-widget-launcher.js');
  const contractPath = path.join(root, 'runtime-contract.json');
  fs.writeFileSync(secretPath, secret.toString('base64'));
  fs.writeFileSync(launcherPath, 'module.exports = {};\n');
  fs.writeFileSync(contractPath, JSON.stringify({
    control: { healthPathBase: '/api/health/contracts', apiVersion: 'test-control' },
    runtime: { healthPath: '/health', apiVersion: 'test-runtime' },
  }));
  const instanceId = crypto.randomUUID().replaceAll('-', '');
  const bootstrap = {
    schema: broker.BROKER_SCHEMA,
    instanceId,
    instanceRoot: root,
    secretPath,
    activationPath: path.join(root, 'activation.json'),
    ownershipPath: path.join(root, 'ownership.json'),
    eventsPath: path.join(root, 'events.jsonl'),
    pipeName: `\\\\.\\pipe\\WorkspaceWidget.AxStore.Test.${instanceId}`,
    launcherPath,
    contractPath,
  };
  const bootstrapPath = path.join(root, 'bootstrap.json');
  fs.writeFileSync(bootstrapPath, JSON.stringify(bootstrap));
  const activation = {
    instanceId,
    pid: process.pid,
    processCreationTimeUtc: new Date().toISOString(),
    executablePath: process.execPath,
    executableSha256: broker.sha256(fs.readFileSync(process.execPath)),
    commandLineSha256: broker.sha256(process.argv.join(' ')),
    brokerSha256: broker.sha256(fs.readFileSync(require.resolve('../app/ax-store-lifecycle-broker'))),
    launcherSha256: broker.sha256(fs.readFileSync(launcherPath)),
    contractSha256: broker.sha256(fs.readFileSync(contractPath)),
  };
  fs.writeFileSync(bootstrap.activationPath, JSON.stringify(broker.signed(secret, activation)));
  return { root, secret, bootstrap, bootstrapPath };
}

function request(pipeName, document, prefix = '') {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(pipeName);
    let body = '';
    client.setEncoding('utf8');
    client.on('connect', () => client.write(`${prefix}${JSON.stringify(document)}\n`));
    client.on('data', (chunk) => { body += chunk; });
    client.on('end', () => resolve(JSON.parse(body.trim())));
    client.on('error', reject);
  });
}

test('broker rejects a tampered activation before claiming ownership', async () => {
  const value = fixture();
  const activation = JSON.parse(fs.readFileSync(value.bootstrap.activationPath, 'utf8'));
  activation.payload.pid += 1;
  fs.writeFileSync(value.bootstrap.activationPath, JSON.stringify(activation));
  const fake = { launchFromWorkspaceWidget: async () => assert.fail('launcher must not run') };
  await assert.rejects(() => broker.runBroker({ bootstrapPath: value.bootstrapPath }, { launcher: fake }), /verification/);
  assert.equal(fs.existsSync(value.bootstrap.ownershipPath), false);
});

test('signed stop is graceful and writes a signed completion receipt', async () => {
  const value = fixture();
  let stops = 0;
  const fake = {
    registerShutdownHandlers() { return async () => { stops += 1; }; },
    async launchFromWorkspaceWidget(options) {
      options.shutdownRegistrar({});
      return { status: 'SUCCEEDED', instance: {} };
    },
    async inspectRuntime() {
      return { reachableCount: 0, observations: [
        { url: 'http://127.0.0.1:4520/health', reachable: false },
        { url: 'http://127.0.0.1:4521/health', reachable: false },
      ] };
    },
  };
  const running = await broker.runBroker({ bootstrapPath: value.bootstrapPath }, { launcher: fake });
  const ownership = JSON.parse(fs.readFileSync(value.bootstrap.ownershipPath, 'utf8'));
  const payload = {
    schema: broker.BROKER_SCHEMA,
    action: 'STOP',
    instanceId: value.bootstrap.instanceId,
    requestId: crypto.randomUUID().replaceAll('-', ''),
    ownershipDigest: broker.sha256(broker.stable(ownership)),
    reason: 'test graceful stop',
    acknowledgedImpact: true,
    requestedAt: new Date().toISOString(),
  };
  const response = await request(value.bootstrap.pipeName, broker.signed(value.secret, payload));
  assert.equal(response.payload.status, 'STOPPED');
  assert.equal(stops, 1);
  assert.equal(fs.existsSync(path.join(value.root, `stop-completed-${payload.requestId}.json`)), true);
  await new Promise((resolve) => running.server.close(resolve));
});

test('receipt prewrite failure denies stop without calling shutdown', async () => {
  const value = fixture();
  let stops = 0;
  const fake = {
    registerShutdownHandlers() { return async () => { stops += 1; }; },
    async launchFromWorkspaceWidget(options) { options.shutdownRegistrar({}); return { status: 'SUCCEEDED', instance: {} }; },
    async inspectRuntime() { return { reachableCount: 0, observations: [] }; },
  };
  const running = await broker.runBroker({ bootstrapPath: value.bootstrapPath }, { launcher: fake });
  const ownership = JSON.parse(fs.readFileSync(value.bootstrap.ownershipPath, 'utf8'));
  const requestId = crypto.randomUUID().replaceAll('-', '');
  fs.writeFileSync(path.join(value.root, `stop-requested-${requestId}.json`), 'collision');
  const payload = { schema: broker.BROKER_SCHEMA, action: 'STOP', instanceId: value.bootstrap.instanceId, requestId, ownershipDigest: broker.sha256(broker.stable(ownership)), reason: 'receipt collision', acknowledgedImpact: true, requestedAt: new Date().toISOString() };
  const response = await request(value.bootstrap.pipeName, broker.signed(value.secret, payload));
  assert.equal(response.payload.status, 'DENIED_OR_FAILED');
  assert.equal(stops, 0);
  await new Promise((resolve) => running.server.close(resolve));
});

test('blank framing is ignored and a later signed request still succeeds', async () => {
  const value = fixture();
  let stops = 0;
  const fake = {
    registerShutdownHandlers() { return async () => { stops += 1; }; },
    async launchFromWorkspaceWidget(options) { options.shutdownRegistrar({}); return { status: 'SUCCEEDED', instance: {} }; },
    async inspectRuntime() { return { reachableCount: 0, observations: [] }; },
  };
  const running = await broker.runBroker({ bootstrapPath: value.bootstrapPath }, { launcher: fake });
  const ownership = JSON.parse(fs.readFileSync(value.bootstrap.ownershipPath, 'utf8'));
  const payload = { schema: broker.BROKER_SCHEMA, action: 'STOP', instanceId: value.bootstrap.instanceId, requestId: crypto.randomUUID().replaceAll('-', ''), ownershipDigest: broker.sha256(broker.stable(ownership)), reason: 'blank framing test', acknowledgedImpact: true, requestedAt: new Date().toISOString() };
  const response = await request(value.bootstrap.pipeName, broker.signed(value.secret, payload), '\n');
  assert.equal(response.payload.status, 'STOPPED');
  assert.equal(stops, 1);
  await new Promise((resolve) => running.server.close(resolve));
});

test('malformed and oversized requests fail closed without shutdown', async () => {
  const value = fixture();
  let stops = 0;
  const fake = {
    registerShutdownHandlers() { return async () => { stops += 1; }; },
    async launchFromWorkspaceWidget(options) { options.shutdownRegistrar({}); return { status: 'SUCCEEDED', instance: {} }; },
    async inspectRuntime() { return { reachableCount: 0, observations: [] }; },
  };
  const running = await broker.runBroker({ bootstrapPath: value.bootstrapPath }, { launcher: fake });
  const malformed = await new Promise((resolve, reject) => {
    const client = net.createConnection(value.bootstrap.pipeName);
    let body = '';
    client.setEncoding('utf8');
    client.on('connect', () => client.write('{not-json}\n'));
    client.on('data', (chunk) => { body += chunk; });
    client.on('end', () => resolve(JSON.parse(body.trim())));
    client.on('error', reject);
  });
  assert.equal(malformed.payload.status, 'DENIED_OR_FAILED');
  await new Promise((resolve) => {
    const client = net.createConnection(value.bootstrap.pipeName);
    client.on('connect', () => client.write(`${'x'.repeat(70 * 1024)}\n`));
    client.on('error', resolve);
    client.on('close', resolve);
  });
  assert.equal(stops, 0);
  await new Promise((resolve) => running.server.close(resolve));
});

test('pipe collision prevents launch and never publishes ownership', async () => {
  const value = fixture();
  const blocker = net.createServer();
  await new Promise((resolve, reject) => { blocker.once('error', reject); blocker.listen(value.bootstrap.pipeName, resolve); });
  let launches = 0;
  const fake = { async launchFromWorkspaceWidget() { launches += 1; return { status: 'SUCCEEDED', instance: {} }; } };
  await assert.rejects(() => broker.runBroker({ bootstrapPath: value.bootstrapPath }, { launcher: fake }), /EADDRINUSE/);
  assert.equal(launches, 0);
  assert.equal(fs.existsSync(value.bootstrap.ownershipPath), false);
  await new Promise((resolve) => blocker.close(resolve));
});

test('post-launch ownership failure rolls back gracefully', async () => {
  const value = fixture();
  fs.writeFileSync(value.bootstrap.ownershipPath, 'collision');
  let stops = 0;
  const fake = {
    registerShutdownHandlers() { return async () => { stops += 1; }; },
    async launchFromWorkspaceWidget(options) { options.shutdownRegistrar({}); return { status: 'SUCCEEDED', instance: {} }; },
    async inspectRuntime() { return { reachableCount: 0, observations: [] }; },
  };
  await assert.rejects(() => broker.runBroker({ bootstrapPath: value.bootstrapPath }, { launcher: fake }), /EEXIST/);
  assert.equal(stops, 1);
});
