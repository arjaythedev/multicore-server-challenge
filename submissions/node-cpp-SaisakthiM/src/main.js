'use strict';
// Primary process: pre-forks N workers. It never touches a request.
// Rule 9: a crashed server is not restarted, so a worker that dies stays dead (no respawn). The remaining workers
// keep serving (SO_REUSEPORT only routes new connections to live listening sockets); once every worker is gone
// the primary exits too.
// The Postgres connection budget (max_connections = 100, rule: <= 95 in total) is split across the workers.

const { fork } = require('node:child_process');
const os = require('node:os');
const path = require('node:path');

function intEnv(name, dflt) {
  const v = process.env[name];
  if (v === undefined || v === '') return dflt;
  const n = Number.parseInt(v, 10);
  if (!Number.isFinite(n) || n < 0) throw new Error(name + ' must be a non-negative integer');
  return n;
}

for (const name of ['DATABASE_URL', 'JWT_SECRET']) {
  if (!process.env[name]) {
    console.error(name + ' is not set');
    process.exit(1);
  }
}

const cores = typeof os.availableParallelism === 'function' ? os.availableParallelism() : os.cpus().length;
const workers = Math.max(1, intEnv('WORKERS', cores));
let readConns = Math.max(1, intEnv('READ_CONNS', 4));
let writeConns = Math.max(1, intEnv('WRITE_CONNS', 2));
const MAX_PG = 95;
while ((readConns + writeConns) * workers > MAX_PG && readConns > 1) readConns--;
while ((readConns + writeConns) * workers > MAX_PG && writeConns > 1) writeConns--;
if ((readConns + writeConns) * workers > MAX_PG) {
  console.error(`WORKERS=${workers} cannot fit in ${MAX_PG} Postgres connections`);
  process.exit(1);
}

const workerFile = path.join(__dirname, 'worker.js');
const execArgv = [...process.execArgv, ...(process.env.NODE_WORKER_FLAGS
  ? process.env.NODE_WORKER_FLAGS.split(/\s+/).filter(Boolean)
  : ['--max-semi-space-size=32'])];

console.error(`[main] ${workers} workers x (${readConns} read + ${writeConns} write) Postgres connections = ${(readConns + writeConns) * workers}`);

const children = new Map();
let stopping = false;

function spawn(i) {
  const child = fork(workerFile, [], {
    env: { ...process.env, WORKER_ID: String(i), READ_CONNS: String(readConns), WRITE_CONNS: String(writeConns) },
    execArgv,
    stdio: ['ignore', 'inherit', 'inherit', 'ipc'],
  });
  children.set(i, child);
  child.on('exit', (code, signal) => {
    children.delete(i);
    if (stopping) return;
    console.error(`[main] worker ${i} exited (${signal || code}); NOT restarting (a crashed server stays down)`);
    if (children.size === 0) {
      console.error('[main] all workers are gone; exiting');
      process.exit(1);
    }
  });
}

for (let i = 0; i < workers; i++) spawn(i);

function stop() {
  if (stopping) return;
  stopping = true;
  for (const c of children.values()) c.kill('SIGTERM');
  setTimeout(() => process.exit(0), 1500).unref();
  if (children.size === 0) process.exit(0);
}
process.on('SIGTERM', stop);
process.on('SIGINT', stop);