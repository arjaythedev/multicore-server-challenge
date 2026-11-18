// bcrypt, cost 10, interleaved: native/bcrypt.c runs up to six hashes round by round in one call (bcrypt is a chain
// of dependent S-box loads; independent chains overlap), about 4x less CPU per hash than one at a time (measured:
// 11 ms vs 44 ms, the same as Bun.password). A single worker sees too few logins to fill a set, so the
// supervisor process runs bcrypt for all of them: workers send jobs over Bun's IPC, the supervisor gathers them
// into sets on its bcrypt threads (bcrypt-thread.ts).
import { Worker } from 'node:worker_threads';
import { randomBytes, timingSafeEqual } from 'node:crypto';

// ---- in the supervisor

// Returns run(pw, setting, done): done(hash or null). A partial set waits up to waitMs for company; a hash of
// another cost runs alone.
type Done = (hash: string | null) => void;
type Job = { pw: string; setting: string; done: Done };
type Thread = { busy: boolean; jobs: Job[] | null; w: Worker };
export function bcryptService({ threads = 2, waitMs = 100 } = {}) {
  let lanes = 4; // until the first thread has calibrated
  const queue: Job[] = [];
  let timer: Timer | null = null, due = false;
  const pool = Array.from({ length: threads }, (_, i) => {
    const t: Thread = { busy: i === 0, jobs: null, w: new Worker(new URL('./bcrypt-thread.ts', import.meta.url), { workerData: { calibrate: i === 0, maxLanes: 6 } }) };
    t.w.on('message', (r: (string | null)[] | { lanes: number; ns: number }) => {
      if (!Array.isArray(r)) lanes = r.lanes; // calibration result
      else t.jobs!.forEach((j, k) => j.done(r[k]));
      t.busy = false;
      t.jobs = null;
      pump();
    });
    t.w.on('error', (e) => { console.error('bcrypt thread failed', e); process.exit(1); });
    return t;
  });
  const cost10 = (s: string) => s.startsWith('$2') && s.slice(4, 7) === '10$';
  function pump() {
    while (queue.length > 0) {
      const t = pool.find((x) => !x.busy);
      if (!t) return;
      const odd = queue.findIndex((j) => !cost10(j.setting));
      let jobs: Job[];
      if (odd >= 0) jobs = queue.splice(odd, 1);
      else if (queue.length >= lanes || due) jobs = queue.splice(0, lanes);
      else {
        timer ??= setTimeout(() => { timer = null; due = true; pump(); }, waitMs);
        return;
      }
      t.busy = true;
      t.jobs = jobs;
      t.w.postMessage({ pws: jobs.map((j) => Buffer.from(j.pw, 'utf8')), settings: jobs.map((j) => j.setting) });
    }
    due = false;
  }
  return (pw: string, setting: string, done: Done) => { queue.push({ pw, setting, done }); pump(); };
}

// ---- in a worker

const waiting = new Map<number, Done>();
let seq = 0;
process.on('message', ({ id, hash }: { id: number; hash: string | null }) => { waiting.get(id)!(hash); waiting.delete(id); });
const run = (pw: string, setting: string) => new Promise<string | null>((resolve) => {
  const id = ++seq;
  waiting.set(id, resolve);
  process.send!({ id, pw, setting });
});

const BF64 = './ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
function newSetting() { // "$2b$10$" + 22 characters of bcrypt base64 from 16 random bytes
  const r = randomBytes(16);
  let s = '$2b$10$';
  for (let i = 0; i < 16; i += 3) {
    const a = r[i], b = i + 1 < 16 ? r[i + 1] : 0, c = i + 2 < 16 ? r[i + 2] : 0;
    s += BF64[a >> 2] + BF64[((a & 3) << 4) | (b >> 4)];
    if (i + 1 < 16) s += BF64[((b & 15) << 2) | (c >> 6)] + BF64[c & 63];
  }
  return s.slice(0, 29);
}

export async function hash(pw: string) {
  const h = await run(pw, newSetting());
  if (h === null) throw new Error('bcrypt failed');
  return h;
}

export async function verify(pw: string, stored: string) {
  const got = await run(pw, stored);
  return got !== null && got.length === stored.length && timingSafeEqual(Buffer.from(got), Buffer.from(stored));
}
