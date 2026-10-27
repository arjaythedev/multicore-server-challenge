'use strict';
// One worker process: its own event loop, its own addon instance (Postgres lanes + bcrypt threads), and its own
// listening socket on the shared port (SO_REUSEPORT: the kernel spreads connections across workers).

const http = require('node:http');
const { performance } = require('node:perf_hooks');
const pg = require('./pg');
const { handle } = require('./handlers');

function intEnv(name, dflt) {
  const v = process.env[name];
  if (v === undefined || v === '') return dflt;
  const n = Number.parseInt(v, 10);
  if (!Number.isFinite(n) || n < 0) throw new Error(name + ' must be a non-negative integer');
  return n;
}

pg.init({
  url: process.env.DATABASE_URL,
  secret: process.env.JWT_SECRET,
  readConns: intEnv('READ_CONNS', 4),
  writeConns: intEnv('WRITE_CONNS', 2),
  bcryptThreads: intEnv('BCRYPT_THREADS', 2),
  sslmode: process.env.PG_SSLMODE || 'disable',
});

const server = http.createServer((req, res) => {
  handle(req, res).catch((err) => {
    console.error('[http] unhandled error:', err && err.stack ? err.stack : err);
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end('{"errors":{"body":["internal error"]}}');
    } else {
      res.destroy();
    }
  });
});
// Keep idle keep-alive connections far longer than Nginx's 60 s upstream timeout and a user's think time (max 70 s).
server.keepAliveTimeout = 125000;
server.headersTimeout = 130000;
server.requestTimeout = 0;

server.listen({
  host: process.env.HOST || '127.0.0.1',
  port: intEnv('PORT', 3000),
  backlog: 4096,
  reusePort: true,
});

// the primary's IPC channel closing means the primary is gone: don't keep the port
process.on('disconnect', () => process.exit(0));

if (process.env.CONDUIT_STATS === '1') {
  let last = performance.eventLoopUtilization();
  setInterval(() => {
    const now = performance.eventLoopUtilization();
    const d = performance.eventLoopUtilization(now, last);
    last = now;
    console.error(`[stats] worker ${process.env.WORKER_ID} elu=${d.utilization.toFixed(2)} rss=${(process.memoryUsage.rss() / 1048576) | 0}MB`);
  }, 5000).unref();
}
