'use strict';

const net = require('node:net');

const pipeName = process.argv[2];
if (!/^\\\\\.\\pipe\\WorkspaceWidget\.AxStore\.AclProbe\.[0-9a-f]{32}$/.test(pipeName || '')) {
  throw new Error('A bounded ACL probe pipe name is required.');
}

const server = net.createServer((socket) => {
  socket.on('error', () => {});
  socket.resume();
});
server.maxConnections = 4;
server.listen(pipeName, () => process.stdout.write('READY\n'));
setTimeout(() => {
  server.close();
  process.exitCode = 2;
}, 30_000);
