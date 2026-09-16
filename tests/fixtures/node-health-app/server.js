const http = require("node:http");

const port = Number.parseInt(process.argv[2] || "43999", 10);
const probeToken = process.argv[3] || "development-fixture";
const server = http.createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify({ status: "ok", runtime: process.version, probeToken })
    );
    return;
  }

  response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
  response.end("Workspace Widget bundled Node startup fixture");
});

server.listen(port, "127.0.0.1");

process.on("SIGBREAK", () => {
  server.close(() => {
    if (process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_PATH && process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_TOKEN) {
      require("node:fs").writeFileSync(
        process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_PATH,
        process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_TOKEN,
        "utf8"
      );
    }
    process.exit(0);
  });
  server.closeIdleConnections?.();
});
