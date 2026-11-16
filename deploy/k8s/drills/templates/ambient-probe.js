// Connection probe of the drills, run in a pod that has node (the web image):
//   kubectl exec <pod> -- /nodejs/bin/node -e "$(cat deploy/k8s/drills/templates/ambient-probe.js)" MODE TARGET
// It prints one line: how the name resolved (ip, dns, nodns: a closed port behind a name that does not resolve proves
// nothing), then the state. Design notes: docs/reference/k8s.md.

// In a pod ambient mode captures, ztunnel accepts every TCP connection in the pod before it dials the target, so a
// connect alone proves nothing. A socket ztunnel closes or resets before W is closed; one still open at W, or that got
// data, reached the target. W is above ztunnel's fixed 10 s upstream connect timeout (CONNECTION_TIMEOUT of
// src/proxy.rs in ztunnel) with a margin.
const W = 15000;

// MODE tcp, TARGET host:port or http://host:port (a HEAD request first, so a server that drops a silent connection
// early answers): open or closed. MODE grpc, TARGET host:port, a plaintext gRPC health check: unreached (no connect by
// W, told only from a pod ambient does not capture), refused (closed before an answer), silent (no answer by W) or
// answered http=<status> grpc=<code>. MODE connect: connected or unreached, from a pod ambient does not capture.
const net = require("node:net");
const dns = require("node:dns");
const http2 = require("node:http2");

const [mode = "", spec = ""] = process.argv.slice(1);
const http = spec.startsWith("http://");
const target = http ? spec.slice("http://".length) : spec;
const i = target.lastIndexOf(":");
const host = target.slice(0, i);
const port = Number(target.slice(i + 1));

const probe = (resolved) => {
  let over = false;
  let connected = false;
  let answer = "";
  let session;
  const socket = net.connect({ host, port });
  const end = (state) => {
    if (over) return;
    over = true;
    clearTimeout(timer);
    if (session) session.destroy();
    socket.destroy();
    console.log(`${resolved} ${state}`);
  };
  const timer = setTimeout(() => {
    if (mode === "tcp") end(connected ? "open" : "closed");
    else if (mode === "grpc") end(connected ? "silent" : "unreached");
    else end("unreached");
  }, W);
  socket.once("connect", () => {
    connected = true;
    if (mode === "connect") end("connected");
    else if (mode === "tcp" && http) socket.write(`HEAD / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`);
  });
  socket.once("error", () => {});
  socket.once("close", () => {
    if (mode === "tcp") end("closed");
    else if (mode === "grpc") end(answer || (connected ? "refused" : "unreached"));
    else end("unreached");
  });
  if (mode === "tcp") socket.once("data", () => end("open"));
  if (mode !== "grpc") return;

  session = http2.connect(`http://${target}`, { createConnection: () => socket });
  session.on("error", () => {});
  // An empty HealthCheckRequest (service ""): the server's overall health.
  const req = session.request({
    ":method": "POST",
    ":path": "/grpc.health.v1.Health/Check",
    "content-type": "application/grpc",
    te: "trailers",
  });
  let status = "";
  let code = "";
  req.on("error", () => {});
  req.on("response", (headers) => {
    status = String(headers[":status"]);
    code = headers["grpc-status"] ?? "";
    answer = `answered http=${status} grpc=${code}`;
  });
  req.on("trailers", (trailers) => {
    code = trailers["grpc-status"] ?? code;
    answer = `answered http=${status} grpc=${code}`;
  });
  req.on("end", () => end(answer || "refused"));
  req.resume();
  req.end(Buffer.alloc(5));
};

if (!["tcp", "grpc", "connect"].includes(mode) || !host || !Number.isInteger(port)) {
  console.log(`usage: MODE tcp|grpc|connect, TARGET host:port (got ${mode} ${spec})`);
  process.exit(2);
}
if (net.isIP(host) !== 0) probe("ip");
else dns.lookup(host, (error) => probe(error ? "nodns" : "dns"));
