// A bcrypt thread: runs a set of up to six hashes interleaved in native code (bin/libbcrypt.so through bun:ffi),
// blocking this thread only.
import { parentPort as port, workerData } from 'node:worker_threads';
import { dirname, join } from 'node:path';
import { dlopen, FFIType } from 'bun:ffi';

const parentPort = port!; // always set: this file only runs as a worker
// built by build.sh; next to the executable when compiled (bun compile)
const root = import.meta.dir.startsWith('/$bunfs/') ? dirname(process.execPath) : join(import.meta.dir, '..');
const lib = dlopen(join(root, 'bin', 'libbcrypt.so'), {
  bc_hash: { args: [FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  bc_selftest: { args: [], returns: FFIType.i32 },
  bc_calibrate: { args: [FFIType.u32], returns: FFIType.f64 },
}).symbols;

const KEY_SLOT = 73, SET_SLOT = 64, OUT_SLOT = 61, MAX_LANES = 6;
const keys = new Uint8Array(KEY_SLOT * MAX_LANES);
const settings = new Uint8Array(SET_SLOT * MAX_LANES);
const out = new Uint8Array(OUT_SLOT * MAX_LANES);
const enc = new TextEncoder();

if (!lib.bc_selftest()) { console.error('bcrypt self-test failed'); process.exit(1); }

// The fastest lane count depends on the CPU (registers, load latency): time each one on a cheap cost and report
// the lane count with the lowest time per hash (only on the first bcrypt thread).
const { calibrate, maxLanes }: { calibrate: boolean; maxLanes: number } = workerData;
if (calibrate) {
  let best = 1, bestNs = Infinity;
  for (let n = 1; n <= maxLanes; n++) {
    lib.bc_calibrate(n);
    const ns = Math.min(lib.bc_calibrate(n), lib.bc_calibrate(n));
    if (ns < bestNs * 0.97) { best = n; bestNs = ns; }
  }
  parentPort.postMessage({ lanes: best, ns: Math.round(bestNs) });
}

function hash(pws: Uint8Array[], sets: string[]) {
  const n = pws.length;
  keys.fill(0); settings.fill(0);
  for (let i = 0; i < n; i++) {
    const p = pws[i];
    if (p.length > 72 || p.indexOf(0) >= 0) return null;
    keys.set(p, i * KEY_SLOT);
    const s = sets[i];
    if (s.length >= SET_SLOT) return null;
    enc.encodeInto(s, settings.subarray(i * SET_SLOT, i * SET_SLOT + SET_SLOT - 1));
  }
  if (!lib.bc_hash(n, keys, settings, out)) return null;
  const r: string[] = new Array(n);
  for (let i = 0; i < n; i++) r[i] = String.fromCharCode(...out.subarray(i * OUT_SLOT, i * OUT_SLOT + 60));
  return r;
}

parentPort.on('message', ({ pws, settings: sets }: { pws: Uint8Array[]; settings: string[] }) => {
  const bufs = pws.map((p) => new Uint8Array(p.buffer, p.byteOffset, p.byteLength));
  const r = hash(bufs, sets) || sets.map(() => null);
  for (const b of bufs) b.fill(0);
  parentPort.postMessage(r);
});
