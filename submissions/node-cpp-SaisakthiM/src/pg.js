'use strict';
// Promise wrapper over the native addon. Requests are identified by a small integer id; the addon calls
// onPg / onBcrypt (once per request) on the event loop.

const native = require('../build/conduit.node');
const { STATEMENTS } = require('./sql');

const pgSlots = [];
const pgFree = [];
const bcSlots = [];
const bcFree = [];

function onPg(id, status, buf, sqlstate) {
  const resolve = pgSlots[id];
  if (resolve === undefined) return;
  pgSlots[id] = undefined;
  pgFree.push(id);
  resolve({ status, buf, sqlstate });
}

function onBcrypt(id, ok, hash) {
  const resolve = bcSlots[id];
  if (resolve === undefined) return;
  bcSlots[id] = undefined;
  bcFree.push(id);
  resolve({ ok, hash });
}

// lane 0 = reads, lane 1 = writes. spec = [stmtIdx, nParams, ...params, stmtIdx, nParams, ...params]
// Resolves { status: 0 row | 1 no row | 2 error, buf: Buffer|null, sqlstate }.
function exec(lane, spec) {
  return new Promise((resolve, reject) => {
    const id = pgFree.length > 0 ? pgFree.pop() : pgSlots.length;
    pgSlots[id] = resolve;
    try {
      native.exec(lane, id, spec);
    } catch (e) {
      pgSlots[id] = undefined;
      pgFree.push(id);
      reject(e);
    }
  });
}

function bcryptJob(start) {
  return new Promise((resolve, reject) => {
    const id = bcFree.length > 0 ? bcFree.pop() : bcSlots.length;
    bcSlots[id] = resolve;
    try {
      start(id);
    } catch (e) {
      bcSlots[id] = undefined;
      bcFree.push(id);
      reject(e);
    }
  });
}

// -> hash string, or null on failure
async function bcryptHash(password) {
  const r = await bcryptJob((id) => native.bcryptHash(id, password));
  return r.ok ? r.hash : null;
}

// -> boolean
async function bcryptVerify(password, hash) {
  const r = await bcryptJob((id) => native.bcryptVerify(id, password, hash));
  return r.ok;
}

function init(opts) {
  native.init({ ...opts, sql: STATEMENTS, onPg, onBcrypt });
}

module.exports = { init, exec, bcryptHash, bcryptVerify };
