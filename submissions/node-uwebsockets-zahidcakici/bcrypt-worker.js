'use strict';
// A bcrypt thread: runs a set of up to six hashes interleaved in the native addon (blocking this thread only).
const { parentPort } = require('worker_threads');
const path = require('path');
const bcrypt = require(path.join(__dirname, 'bin', 'bcrypt.node'));

const { workerData } = require('worker_threads');
if (!bcrypt.selfTest()) { console.error('bcrypt self-test failed'); process.exit(1); }

// The fastest lane count depends on the CPU (registers, load latency): time each one on a cheap cost and report
// the lane count with the lowest time per hash (only on the first bcrypt thread).
if (workerData && workerData.calibrate) {
  let best = 1, bestNs = Infinity;
  for (let n = 1; n <= workerData.maxLanes; n++) {
    bcrypt.calibrate(n);
    const ns = Math.min(bcrypt.calibrate(n), bcrypt.calibrate(n));
    if (ns < bestNs * 0.97) { best = n; bestNs = ns; }
  }
  parentPort.postMessage({ lanes: best, ns: Math.round(bestNs) });
}

parentPort.on('message', ({ pws, settings }) => {
  let out;
  try {
    out = bcrypt.hash(pws.map((p) => Buffer.from(p.buffer, p.byteOffset, p.byteLength)), settings);
  } catch {
    out = settings.map(() => null);
  }
  for (const p of pws) p.fill(0);
  parentPort.postMessage(out);
});
