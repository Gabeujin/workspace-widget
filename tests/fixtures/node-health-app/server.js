const http = require("node:http");

const port = Number.parseInt(process.argv[2] || "43999", 10);
const server = http.createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "ok", runtime: process.version }));
    return;
  }

  response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
  response.end("Workspace Widget bundled Node startup fixture");
});

server.listen(port, "127.0.0.1");
