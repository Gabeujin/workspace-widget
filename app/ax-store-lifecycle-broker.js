'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const BROKER_SCHEMA = 'workspace-widget/ax-store-lifecycle/v1';

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function sha256(input) {
  return crypto.createHash('sha256').update(input).digest('hex');
}

function hmac(secret, payload) {
  return crypto.createHmac('sha256', secret).update(stable(payload)).digest('hex');
}

function signed(secret, payload) {
  return { payload, signature: hmac(secret, payload) };
}

function readSigned(filePath, secret) {
  const document = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  const actual = Buffer.from(String(document.signature || ''), 'hex');
  const expected = Buffer.from(hmac(secret, document.payload), 'hex');
  if (actual.length !== expected.length || !crypto.timingSafeEqual(actual, expected)) {
    throw new Error(`Signed lifecycle document failed verification: ${path.basename(filePath)}`);
  }
  return document.payload;
}

function writeExclusive(filePath, document) {
  fs.writeFileSync(filePath, `${JSON.stringify(document, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
}

function appendEvent(bootstrap, secret, event, detail = {}) {
  const payload = {
    schema: BROKER_SCHEMA,
    event,
    instanceId: bootstrap.instanceId,
    recordedAt: new Date().toISOString(),
    ...detail,
  };
  fs.appendFileSync(bootstrap.eventsPath, `${JSON.stringify(signed(secret, payload))}\n`, 'utf8');
  return payload;
}

async function waitForActivation(bootstrap, secret, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(bootstrap.activationPath)) {
      const activation = readSigned(bootstrap.activationPath, secret);
      if (activation.instanceId !== bootstrap.instanceId || Number(activation.pid) !== process.pid) {
        throw new Error('Activation identity does not match this broker process.');
      }
      return activation;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error('Lifecycle activation did not arrive in time.');
}

function parseArguments(argv) {
  const index = argv.indexOf('--bootstrap');
  if (index < 0 || !argv[index + 1]) throw new Error('--bootstrap is required.');
  return { bootstrapPath: path.resolve(argv[index + 1]) };
}

async function runBroker({ bootstrapPath }, dependencies = {}) {
  const bootstrap = JSON.parse(fs.readFileSync(bootstrapPath, 'utf8'));
  if (bootstrap.schema !== BROKER_SCHEMA || bootstrap.instanceId == null) {
    throw new Error('Unsupported lifecycle bootstrap document.');
  }
  const secret = Buffer.from(fs.readFileSync(bootstrap.secretPath, 'utf8').trim(), 'base64');
  const activation = await waitForActivation(bootstrap, secret);
  const brokerHash = sha256(fs.readFileSync(__filename));
  const launcherHash = sha256(fs.readFileSync(bootstrap.launcherPath));
  const contractBytes = fs.readFileSync(bootstrap.contractPath);
  const contractHash = sha256(contractBytes);
  if (
    activation.brokerSha256 !== brokerHash
    || activation.launcherSha256 !== launcherHash
    || activation.contractSha256 !== contractHash
  ) {
    throw new Error('Activated lifecycle artifacts changed before startup.');
  }

  const launcher = dependencies.launcher || require(bootstrap.launcherPath);
  let gracefulShutdown = null;
  const contract = JSON.parse(contractBytes.toString('utf8'));
  const controlHealthUrl = `http://127.0.0.1:4520${contract.control.healthPathBase}/${contract.control.apiVersion}/${contractHash}`;
  const runtimeHealthUrl = `http://127.0.0.1:4521${contract.runtime.healthPath}`;
  let ownershipDigest = null;
  let lifecycleReady = false;
  const completed = new Map();
  let stopInProgress = false;
  const server = net.createServer({ allowHalfOpen: true }, (socket) => {
    socket.on('error', () => { /* a client may disconnect after its signed request */ });
    socket.setTimeout(5_000, () => socket.destroy(new Error('Lifecycle request timed out.')));
    socket.setEncoding('utf8');
    let requestText = '';
    let handling = false;
    const handleRequest = async () => {
      if (handling) return;
      requestText = requestText.trim();
      if (!requestText) return;
      handling = true;
      let responsePayload;
      try {
        if (!lifecycleReady || !gracefulShutdown || !ownershipDigest) {
          throw new Error('AX Store lifecycle ownership is not ready.');
        }
        const document = JSON.parse(requestText);
        const request = document.payload;
        const actual = Buffer.from(String(document.signature || ''), 'hex');
        const expected = Buffer.from(hmac(secret, request), 'hex');
        if (actual.length !== expected.length || !crypto.timingSafeEqual(actual, expected)) {
          throw new Error('Lifecycle request signature is invalid.');
        }
        const requestedAt = Date.parse(request.requestedAt);
        if (
          request.schema !== BROKER_SCHEMA
          || request.instanceId !== bootstrap.instanceId
          || request.ownershipDigest !== ownershipDigest
          || request.action !== 'STOP'
          || request.acknowledgedImpact !== true
          || typeof request.reason !== 'string'
          || request.reason.trim().length < 3
          || !/^[0-9a-f]{32}$/.test(String(request.requestId || ''))
          || !Number.isFinite(requestedAt)
          || Math.abs(Date.now() - requestedAt) > 60_000
        ) {
          throw new Error('Lifecycle request failed its bounded contract.');
        }
        if (completed.has(request.requestId)) {
          responsePayload = completed.get(request.requestId);
        } else if (stopInProgress) {
          throw new Error('A graceful AX Store stop is already in progress.');
        } else {
          stopInProgress = true;
          const requestedReceiptPath = path.join(bootstrap.instanceRoot, `stop-requested-${request.requestId}.json`);
          writeExclusive(requestedReceiptPath, signed(secret, {
            schema: BROKER_SCHEMA,
            event: 'STOP_REQUESTED',
            instanceId: bootstrap.instanceId,
            requestId: request.requestId,
            reason: request.reason.trim(),
            recordedAt: new Date().toISOString(),
          }));
          let shutdownError = null;
          try {
            await gracefulShutdown('WORKSPACE_WIDGET_OWNED_STOP');
          } catch (error) {
            shutdownError = error;
          }
          let finalHealth = await launcher.inspectRuntime();
          const deadline = Date.now() + 12_000;
          while (finalHealth.reachableCount > 0 && Date.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 200));
            finalHealth = await launcher.inspectRuntime();
          }
          const success = finalHealth.reachableCount === 0;
          responsePayload = {
            schema: BROKER_SCHEMA,
            instanceId: bootstrap.instanceId,
            requestId: request.requestId,
            status: success ? 'STOPPED' : 'PARTIAL_OR_UNKNOWN',
            controlPortClosed: !finalHealth.observations.some((entry) => entry.url.includes(':4520') && entry.reachable),
            runtimePortClosed: !finalHealth.observations.some((entry) => entry.url.includes(':4521') && entry.reachable),
            error: shutdownError ? shutdownError.message : null,
            completedAt: new Date().toISOString(),
          };
          const completedReceiptPath = path.join(bootstrap.instanceRoot, `stop-completed-${request.requestId}.json`);
          writeExclusive(completedReceiptPath, signed(secret, responsePayload));
          completed.set(request.requestId, responsePayload);
          if (success) server.close();
        }
      } catch (error) {
        responsePayload = {
          schema: BROKER_SCHEMA,
          instanceId: bootstrap.instanceId,
          status: 'DENIED_OR_FAILED',
          error: error.message,
          completedAt: new Date().toISOString(),
        };
      }
      socket.end(`${JSON.stringify(signed(secret, responsePayload))}\n`);
    };
    socket.on('data', (chunk) => {
      requestText += chunk;
      if (requestText.length > 64 * 1024) socket.destroy(new Error('Lifecycle request is too large.'));
      if (requestText.includes('\n')) handleRequest();
    });
    socket.on('end', handleRequest);
  });
  server.maxConnections = 4;
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(bootstrap.pipeName, resolve);
  });
  try {
    const launchResult = await launcher.launchFromWorkspaceWidget({
      shutdownRegistrar(instance) {
        gracefulShutdown = launcher.registerShutdownHandlers(instance);
        return gracefulShutdown;
      },
    });
    if (!launchResult || launchResult.status !== 'SUCCEEDED' || !launchResult.instance || !gracefulShutdown) {
      appendEvent(bootstrap, secret, 'NOT_OWNER', { outcome: 'already-running-or-not-started' });
      server.close();
      return { status: 'NOT_OWNER' };
    }
    const ownershipPayload = {
      schema: BROKER_SCHEMA,
      instanceId: bootstrap.instanceId,
      owner: 'Workspace Widget AX Store lifecycle broker',
      pid: process.pid,
      processCreationTimeUtc: activation.processCreationTimeUtc,
      executablePath: activation.executablePath,
      executableSha256: activation.executableSha256,
      commandLineSha256: activation.commandLineSha256,
      brokerPath: __filename,
      brokerSha256: brokerHash,
      launcherPath: bootstrap.launcherPath,
      launcherSha256: launcherHash,
      contractPath: bootstrap.contractPath,
      contractSha256: contractHash,
      controlHealthUrl,
      runtimeHealthUrl,
      pipeName: bootstrap.pipeName,
      capabilitySha256: sha256(secret),
      establishedAt: new Date().toISOString(),
    };
    const ownershipDocument = signed(secret, ownershipPayload);
    ownershipDigest = sha256(stable(ownershipDocument));
    appendEvent(bootstrap, secret, 'CONTROL_PIPE_READY', { ownershipDigest });
    writeExclusive(bootstrap.ownershipPath, ownershipDocument);
    lifecycleReady = true;
    appendEvent(bootstrap, secret, 'OWNERSHIP_ESTABLISHED', { ownershipDigest });
    return { status: 'OWNED', server, ownershipDigest };
  } catch (error) {
    lifecycleReady = false;
    if (gracefulShutdown) {
      try { await gracefulShutdown('WORKSPACE_WIDGET_STARTUP_ROLLBACK'); } catch { /* preserve original failure */ }
    }
    try { server.close(); } catch { /* already closed */ }
    throw error;
  }
}

if (require.main === module) {
  runBroker(parseArguments(process.argv.slice(2))).catch((error) => {
    process.stderr.write(`[Workspace Widget AX Store broker] ${error.stack || error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = { BROKER_SCHEMA, hmac, parseArguments, runBroker, sha256, signed, stable };
