'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const contractPath = path.join(__dirname, 'public', 'runtime-contract.json');
const contractBytes = fs.readFileSync(contractPath);
const contract = JSON.parse(contractBytes.toString('utf8'));

function respondJson(response, status, payload) {
  const body = Buffer.from(JSON.stringify(payload));
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
  });
  response.end(body);
}

const control = http.createServer((request, response) => {
  if (request.url === '/health') {
    respondJson(response, 200, { ok: true, service: 'ax-store-control', status: 'ready' });
    return;
  }
  if (request.url === '/runtime-contract.json') {
    response.writeHead(200, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': contractBytes.length,
    });
    response.end(contractBytes);
    return;
  }
  respondJson(response, 404, { ok: false });
});

const runtime = http.createServer((request, response) => {
  if (request.url === '/health') {
    respondJson(response, 200, { ok: true, service: 'ax-store-runtime', status: 'ready' });
    return;
  }
  respondJson(response, 404, { ok: false });
});

Promise.all([
  new Promise((resolve, reject) => {
    control.once('error', reject);
    control.listen(Number(contract.testControlPort), '127.0.0.1', resolve);
  }),
  new Promise((resolve, reject) => {
    runtime.once('error', reject);
    runtime.listen(Number(contract.testRuntimePort), '127.0.0.1', resolve);
  }),
]).then(() => process.stdout.write('READY\n')).catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
