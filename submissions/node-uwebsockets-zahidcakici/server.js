'use strict';
// Main thread: starts the database thread (db.js), the HTTP threads (http.js) and the bcrypt threads
// (bcrypt-worker.js), and schedules bcrypt: hashes are gathered into sets of up to BCRYPT_LANES, which run
// interleaved.
const { Worker, MessageChannel } = require('worker_threads');
const os = require('os');
const path = require('path');

const env = process.env;
const int = (k, d) => (env[k] !== undefined && env[k] !== '' ? parseInt(env[k], 10) : d);
const cpus = os.availableParallelism ? os.availableParallelism() : os.cpus().length;

const HTTP_THREADS = int('HTTP_THREADS', Math.max(1, Math.round(cpus / 4)));
const DB_THREADS = int('DB_THREADS', cpus >= 6 ? 2 : 1);
// Read connections per database thread: about one Postgres backend per physical core in total (cores / 2 with
// SMT). More backends than that only make them preempt each other in the middle of a batch: locally, 8 read
// connections on 4 cores cost a third more Postgres CPU per request than 4.
const READ_LANES = int('READ_LANES', Math.max(1, Math.round(cpus / 2 / DB_THREADS)));
const BCRYPT_THREADS = int('BCRYPT_THREADS', 2);
let BCRYPT_LANES = Math.min(6, Math.max(1, int('BCRYPT_LANES', 0) || 4)); // calibrated at startup unless set
const BCRYPT_WAIT_MS = int('BCRYPT_WAIT_MS', 200);

if (!env.DATABASE_URL || !env.JWT_SECRET) { console.error('DATABASE_URL and JWT_SECRET are required'); process.exit(1); }
if (DB_THREADS * (READ_LANES + 1) > 95) { console.error('more than 95 Postgres connections'); process.exit(1); }

const shared = {
  databaseUrl: env.DATABASE_URL,
  jwtSecret: env.JWT_SECRET,
  host: env.HOST || '0.0.0.0',
  port: int('PORT', 80),
  readLanes: READ_LANES,
  windowMs: int('READ_WINDOW_MS', 40),
  readMax: int('READ_MAX', 1024),
  writeMax: int('WRITE_MAX', 256),
  idleFlush: int('IDLE_FLUSH', 0) === 1,
  stats: int('STATS', 0) === 1,
  profileS: int('PROFILE_S', 0),
  profileDelayS: int('PROFILE_DELAY_S', 60),
};

// ---- bcrypt scheduling ----
const queue = []; // { worker, id, pw, setting, cost }
const bthreads = [];
let gatherTimer = null;
let gatherDue = false;

function costOf(setting) { return setting.length >= 7 && setting[0] === '$' ? parseInt(setting.substring(4, 6), 10) : -1; }

function pump() {
  for (;;) {
    if (queue.length === 0) { gatherDue = false; return; }
    const t = bthreads.find((b) => !b.busy);
    if (!t) return;
    // a hash of another cost runs alone; otherwise take a full set, or what's there once the gather window ends
    let take;
    const odd = queue.findIndex((j) => j.cost !== 10);
    if (odd >= 0) take = queue.splice(odd, 1);
    else if (queue.length >= BCRYPT_LANES || gatherDue) take = queue.splice(0, BCRYPT_LANES);
    else {
      if (!gatherTimer) gatherTimer = setTimeout(() => { gatherTimer = null; gatherDue = true; pump(); }, BCRYPT_WAIT_MS);
      return;
    }
    if (queue.length === 0) gatherDue = false;
    t.busy = true;
    t.jobs = take;
    t.w.postMessage({ pws: take.map((j) => j.pw), settings: take.map((j) => j.setting) });
  }
}

for (let i = 0; i < BCRYPT_THREADS; i++) {
  const calibrate = i === 0 && !env.BCRYPT_LANES;
  const t = { w: new Worker(path.join(__dirname, 'bcrypt-worker.js'), { workerData: { calibrate, maxLanes: 6 } }), busy: calibrate, jobs: null };
  t.w.on('message', (hashes) => {
    if (!Array.isArray(hashes)) { // calibration result
      BCRYPT_LANES = hashes.lanes;
      console.log(`bcrypt: ${BCRYPT_LANES} lanes (${(hashes.ns / 1e6 * 16).toFixed(1)} ms per cost-10 hash)`);
      t.busy = false;
      pump();
      return;
    }
    const jobs = t.jobs;
    t.jobs = null;
    t.busy = false;
    for (let k = 0; k < jobs.length; k++) jobs[k].worker.postMessage({ t: 'bcrypt', id: jobs[k].id, hash: hashes[k] });
    pump();
  });
  t.w.on('error', (e) => { console.error('bcrypt thread failed', e); process.exit(1); });
  bthreads.push(t);
}

// ---- the database threads, then the HTTP threads (a channel between every HTTP thread and every database thread) ----
const die = (what) => (e) => { console.error(`${what} failed`, e); process.exit(1); };
const channels = Array.from({ length: HTTP_THREADS }, () => Array.from({ length: DB_THREADS }, () => new MessageChannel()));
let dbReady = 0;
for (let d = 0; d < DB_THREADS; d++) {
  const ports = channels.map((row) => row[d].port2);
  const db = new Worker(path.join(__dirname, 'db.js'), { workerData: { ...shared, ports }, transferList: ports });
  db.on('message', (m) => {
    if (m.t === 'bcrypt') {
      const cost = costOf(m.setting);
      if (!(cost >= 4 && cost <= 31)) { db.postMessage({ t: 'bcrypt', id: m.id, hash: null }); return; }
      queue.push({ worker: db, id: m.id, pw: m.pw, setting: m.setting, cost });
      pump();
    } else if (m.t === 'ready' && ++dbReady === DB_THREADS) startHttp();
  });
  // a crashed thread is not restarted (rule 9): stop the whole server
  db.on('error', die('database thread'));
  db.on('exit', (code) => { console.error(`database thread exited (${code})`); process.exit(1); });
}

function startHttp() {
  let ready = 0;
  channels.forEach((row) => {
    const ports_ = row.map((c) => c.port1);
    const w = new Worker(path.join(__dirname, 'http.js'), { workerData: { ...shared, ports_ }, transferList: ports_ });
    w.on('message', (m) => {
      if (m.t === 'ready' && ++ready === HTTP_THREADS) {
        console.log(`listening on ${shared.host}:${shared.port}: ${HTTP_THREADS} HTTP threads, ${DB_THREADS} database threads with ` +
          `${READ_LANES} read connections + 1 write connection each, read window ${shared.windowMs} ms, ${BCRYPT_THREADS} bcrypt threads`);
      }
    });
    w.on('error', die('HTTP thread'));
    w.on('exit', (code) => { console.error(`HTTP thread exited (${code})`); process.exit(1); });
  });
}
