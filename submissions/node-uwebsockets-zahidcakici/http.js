'use strict';
// An HTTP thread: its own uWebSockets.js listener on the shared port (SO_REUSEPORT spreads connections), request
// parsing and validation, and JWT verification. Requests go to a database thread (db.js) in one message per
// event-loop turn; finished responses come back in one message per batch. With several database threads, they take
// turns by time: every thread sends what arrives during window w to database thread w mod n, so each window is
// still one batch for the whole server.
const { workerData, threadId } = require('worker_threads');
const crypto = require('crypto');
const path = require('path');
const uWS = require(path.join(__dirname, 'bin', 'uws.node'));
const { lit } = require('./out');

const cfg = workerData;
const dbPorts = cfg.ports_;
const WINDOW_MS = cfg.windowMs;

// ------------------------------------------------------------------------------------------------
// JWT (HS256): signature, alg and exp checked on every request

const KEY = crypto.createSecretKey(Buffer.from(cfg.jwtSecret, 'utf8'));
const HDR = Buffer.from('{"alg":"HS256","typ":"JWT"}').toString('base64url');
const DAY30 = 30 * 24 * 3600;
const DIGITS = /^[0-9]{1,18}$/;
// returns the user id, or 0 if the token is invalid
function verifyToken(tok) {
  const d1 = tok.indexOf('.');
  if (d1 <= 0) return 0;
  const d2 = tok.indexOf('.', d1 + 1);
  if (d2 < 0 || tok.indexOf('.', d2 + 1) >= 0) return 0;
  if (d2 - d1 > 2048 || tok.length - d2 !== 44) return 0;
  const h = tok.substring(0, d1);
  if (h !== HDR) {
    let hdr;
    try { hdr = JSON.parse(Buffer.from(h, 'base64url').toString('utf8')); } catch { return 0; }
    if (hdr === null || typeof hdr !== 'object' || hdr.alg !== 'HS256') return 0;
  }
  const want = crypto.createHmac('sha256', KEY).update(tok.substring(0, d2)).digest('base64url');
  // constant-time comparison of the two signatures
  let diff = 0;
  for (let i = 0; i < 43; i++) diff |= want.charCodeAt(i) ^ tok.charCodeAt(d2 + 1 + i);
  if (diff !== 0) return 0;
  let claims;
  try { claims = JSON.parse(Buffer.from(tok.substring(d1 + 1, d2), 'base64url').toString('utf8')); } catch { return 0; }
  if (claims === null || typeof claims !== 'object') return 0;
  const now = Date.now() / 1000;
  const exp = claims.exp;
  if (typeof exp !== 'number' || !(exp > now)) return 0;
  const nbf = claims.nbf;
  if (nbf !== undefined && (typeof nbf !== 'number' || nbf > now)) return 0;
  const sub = claims.sub;
  if (typeof sub !== 'string' || !DIGITS.test(sub)) return 0;
  const id = +sub;
  return id > 0 && id <= Number.MAX_SAFE_INTEGER ? id : 0;
}

// ------------------------------------------------------------------------------------------------
// responses

const CT_K = lit('Content-Type');
const CT_V = lit('application/json');
const STATUS = { 200: lit('200 OK'), 201: lit('201 Created'), 204: lit('204 No Content'), 401: lit('401 Unauthorized'), 403: lit('403 Forbidden'), 404: lit('404 Not Found'), 422: lit('422 Unprocessable Entity'), 500: lit('500 Internal Server Error'), 503: lit('503 Service Unavailable') };
const errBody = (m) => lit(`{"errors":{"body":[${JSON.stringify(m)}]}}`);
const E401 = errBody('unauthorized');
const E401_LOGIN = errBody('invalid email or password');
const E403 = errBody('forbidden');
const E404 = errBody('not found');
const E422 = errBody('invalid request');
const E422_TAKEN = errBody('username or email is already taken');
const E500 = errBody('internal error');

let cRes = null, cStatus = 0, cBody = null;
function corked() {
  const r = cRes;
  if (cStatus === 204) { r.writeStatus(STATUS[204]).end(); return; }
  if (cStatus !== 200) r.writeStatus(STATUS[cStatus]);
  r.writeHeader(CT_K, CT_V).end(cBody);
}
// Every response goes out once: an aborted request (client gone) or an answered one is skipped, because uWS
// invalidates the response object and any further access throws.
function send(res, status, body) {
  if (res.aborted || res.done) return;
  res.done = true;
  cRes = res; cStatus = status; cBody = body;
  try { res.cork(corked); } catch (e) { console.error(`[http ${threadId}] send failed: ${e.message}`); }
  cRes = null; cBody = null;
}

const K_TAGS = 0, K_USER = 1, K_LOGIN = 2, K_PROFILE = 3, K_SLUG = 4, K_ID = 5, K_COMMENTS = 6,
  K_GLOBAL = 7, K_TAG = 8, K_AUTHOR = 9, K_FAVORITED = 10, K_FEED = 11;
const W_REGISTER = 0, W_UPDUSER = 1, W_FOLLOW = 2, W_UNFOLLOW = 3, W_FAV = 4, W_UNFAV = 5, W_NEWART = 6,
  W_UPDART = 7, W_DELART = 8, W_NEWCMT = 9, W_DELCMT = 10;

// ------------------------------------------------------------------------------------------------
// to and from the database thread

const waiting = new Map(); // request id -> res
let seq = 0;
let outbox = [];
let flushQueued = false;
function flushOut() {
  flushQueued = false;
  const m = outbox;
  outbox = [];
  const d = dbPorts.length === 1 ? 0 : Math.floor(Date.now() / WINDOW_MS) % dbPorts.length;
  dbPorts[d].postMessage(m);
}
function submit(res, k, v, key, lim, off, token, a) {
  seq = (seq + 1) & 0x7fffffff;
  waiting.set(seq, res);
  outbox.push(seq, k, v, key, lim, off, token, a);
  if (!flushQueued) { flushQueued = true; setImmediate(flushOut); }
}
const read = (res, j) => submit(res, j.k, j.v, j.key, j.lim, j.off, j.token, j.a);
const write = (res, j) => submit(res, 100 + j.k, j.v, null, 0, 0, j.token, j.a);

const onReplies = ({ meta, buf }) => {
  const b = Buffer.from(buf);
  let start = 0;
  for (let i = 0; i < meta.length; i += 3) {
    const id = meta[i], end = meta[i + 2];
    const res = waiting.get(id);
    if (res !== undefined) { waiting.delete(id); send(res, meta[i + 1], b.subarray(start, end)); }
    start = end;
  }
};
for (const p of dbPorts) p.on('message', onReplies);

// the request as the database thread needs it
class Job {
  constructor(k, v) { this.k = k; this.v = v; this.key = null; this.lim = 0; this.off = 0; this.token = null; this.a = null; }
}

function dec(s) {
  if (s.indexOf('%') < 0 && s.indexOf('+') < 0) return s;
  try { return decodeURIComponent(s.replace(/\+/g, ' ')); } catch { return null; }
}
function decParam(s) {
  if (s.indexOf('%') < 0) return s;
  try { return decodeURIComponent(s); } catch { return null; }
}
const COUNT = /^[0-9]{1,16}$/;
function num(s) { // a non-negative decimal integer, or -1
  if (!COUNT.test(s)) return -1;
  const n = +s;
  return n <= Number.MAX_SAFE_INTEGER ? n : -1;
}

// viewer: user id, 0 for no header, -1 for an invalid token
function auth(req) {
  const h = req.getHeader('authorization');
  if (h.length === 0) return 0;
  if (h.length < 7 || !h.startsWith('Token ')) return -1;
  const id = verifyToken(h.substring(6));
  return id === 0 ? -1 : id;
}

function readJson(res, cb) {
  let chunks = null;
  res.onData((ab, isLast) => {
    if (!isLast) { (chunks || (chunks = [])).push(Buffer.from(Buffer.from(ab))); return; }
    let buf = Buffer.from(ab);
    if (chunks) { chunks.push(Buffer.from(buf)); buf = Buffer.concat(chunks); chunks = null; }
    if (buf.length > 1 << 20) { send(res, 422, E422); return; }
    let v;
    try { v = JSON.parse(buf.toString('utf8')); } catch { v = undefined; }
    cb(v);
  });
}

const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);
const nonEmpty = (x) => typeof x === 'string' && x.length > 0;
const optStr = (x) => x === undefined || x === null || typeof x === 'string';

// uWS calls the abort handler without a receiver, so it closes over res
function begin(res) { res.aborted = false; res.done = false; res.onAborted(() => { res.aborted = true; }); }


function listQuery(q, j) { // fills lim/off and the filter; false -> 422
  j.lim = 20; j.off = 0;
  let tag = null, author = null, favorited = null, seenL = false, seenO = false;
  if (q) {
    const parts = q.split('&');
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      const eq = part.indexOf('=');
      const k = dec(eq < 0 ? part : part.substring(0, eq));
      const raw = eq < 0 ? '' : part.substring(eq + 1);
      if (k === 'limit') {
        if (seenL) continue; seenL = true;
        const n = num(dec(raw) || '');
        if (n < 1 || n > 100) return false;
        j.lim = n;
      } else if (k === 'offset') {
        if (seenO) continue; seenO = true;
        const n = num(dec(raw) || '');
        if (n < 0) return false;
        j.off = n;
      } else if (k === 'tag') { if (tag === null) tag = dec(raw) || ''; }
      else if (k === 'author') { if (author === null) author = dec(raw) || ''; }
      else if (k === 'favorited') { if (favorited === null) favorited = dec(raw) || ''; }
    }
  }
  if (tag) { j.k = K_TAG; j.key = tag; }
  else if (author) { j.k = K_AUTHOR; j.key = author; }
  else if (favorited) { j.k = K_FAVORITED; j.key = favorited; }
  else j.k = K_GLOBAL;
  return true;
}

function routes(app) {
  app.get('/api/tags', (res) => { begin(res); read(res, new Job(K_TAGS, 0)); });

  app.get('/api/user', (res, req) => {
    const v = auth(req);
    if (v <= 0) { send(res, 401, E401); return; }
    begin(res);
    const j = new Job(K_USER, v);
    j.token = req.getHeader('authorization').substring(6);
    read(res, j);
  });

  app.put('/api/user', (res, req) => {
    const v = auth(req);
    const token = v > 0 ? req.getHeader('authorization').substring(6) : null;
    begin(res);
    readJson(res, (body) => {
      if (v <= 0) { send(res, 401, E401); return; }
      const u = isObj(body) ? body.user : undefined;
      if (!isObj(u)) { send(res, 422, E422); return; }
      const { email, username, password, bio, image } = u;
      if (!optStr(email) || !optStr(username) || !optStr(password) || !optStr(bio) || !optStr(image)) { send(res, 422, E422); return; }
      if (email === '' || username === '' || password === '') { send(res, 422, E422); return; }
      if (typeof password === 'string' && (Buffer.byteLength(password) > 72 || password.indexOf('\0') >= 0)) { send(res, 422, E422); return; }
      const j = new Job(W_UPDUSER, v);
      j.token = token;
      j.a = { email: email ?? null, username: username ?? null, password: password ?? null, hash: null, bio: bio ?? null, image: image ?? null };
      write(res, j);
    });
  });

  app.post('/api/users', (res) => {
    begin(res);
    readJson(res, (body) => {
      const u = isObj(body) ? body.user : undefined;
      if (!isObj(u) || !nonEmpty(u.username) || !nonEmpty(u.email) || !nonEmpty(u.password)) { send(res, 422, E422); return; }
      if (Buffer.byteLength(u.password) > 72 || u.password.indexOf('\0') >= 0) { send(res, 422, E422); return; }
      const j = new Job(W_REGISTER, 0);
      j.a = { username: u.username, email: u.email, password: u.password, hash: null };
      write(res, j);
    });
  });

  app.post('/api/users/login', (res) => {
    begin(res);
    readJson(res, (body) => {
      const u = isObj(body) ? body.user : undefined;
      if (!isObj(u) || !nonEmpty(u.email) || !nonEmpty(u.password)) { send(res, 422, E422); return; }
      const pw = Buffer.from(u.password, 'utf8');
      if (pw.length > 72 || pw.indexOf(0) >= 0) { send(res, 401, E401_LOGIN); return; }
      const j = new Job(K_LOGIN, 0);
      j.key = u.email;
      j.a = u.password;
      read(res, j);
    });
  });

  app.get('/api/profiles/:username', (res, req) => {
    const v = auth(req);
    if (v < 0) { send(res, 401, E401); return; }
    const name = decParam(req.getParameter(0));
    if (!name) { send(res, 404, E404); return; }
    begin(res);
    const j = new Job(K_PROFILE, v);
    j.key = name;
    read(res, j);
  });

  const follow = (on) => (res, req) => {
    const v = auth(req);
    if (v <= 0) { send(res, 401, E401); return; }
    const name = decParam(req.getParameter(0));
    if (!name) { send(res, 404, E404); return; }
    begin(res);
    const j = new Job(on ? W_FOLLOW : W_UNFOLLOW, v);
    j.a = { username: name };
    write(res, j);
  };
  app.post('/api/profiles/:username/follow', follow(true));
  app.del('/api/profiles/:username/follow', follow(false));

  app.get('/api/articles', (res, req) => {
    const v = auth(req);
    if (v < 0) { send(res, 401, E401); return; }
    const j = new Job(K_GLOBAL, v);
    if (!listQuery(req.getQuery(), j)) { send(res, 422, E422); return; }
    begin(res);
    read(res, j);
  });

  app.get('/api/articles/feed', (res, req) => {
    const v = auth(req);
    if (v <= 0) { send(res, 401, E401); return; }
    const j = new Job(K_FEED, v);
    if (!listQuery(req.getQuery(), j)) { send(res, 422, E422); return; }
    j.k = K_FEED;
    begin(res);
    read(res, j);
  });

  app.get('/api/articles/:slug', (res, req) => {
    const v = auth(req);
    if (v < 0) { send(res, 401, E401); return; }
    const slug = decParam(req.getParameter(0));
    if (!slug) { send(res, 404, E404); return; }
    begin(res);
    const j = new Job(K_SLUG, v);
    j.key = slug;
    read(res, j);
  });

  app.post('/api/articles', (res, req) => {
    const v = auth(req);
    begin(res);
    readJson(res, (body) => {
      if (v <= 0) { send(res, 401, E401); return; }
      const a = isObj(body) ? body.article : undefined;
      if (!isObj(a) || !nonEmpty(a.title) || !nonEmpty(a.description) || !nonEmpty(a.body)) { send(res, 422, E422); return; }
      let tags = a.tagList;
      if (tags === undefined || tags === null) tags = [];
      if (!Array.isArray(tags)) { send(res, 422, E422); return; }
      for (const t of tags) if (!nonEmpty(t)) { send(res, 422, E422); return; }
      const j = new Job(W_NEWART, v);
      j.a = { title: a.title, description: a.description, body: a.body, tags: [...new Set(tags)] };
      write(res, j);
    });
  });

  app.put('/api/articles/:slug', (res, req) => {
    const v = auth(req);
    const slug = decParam(req.getParameter(0));
    begin(res);
    readJson(res, (body) => {
      if (v <= 0) { send(res, 401, E401); return; }
      const a = isObj(body) ? body.article : undefined;
      if (!isObj(a)) { send(res, 422, E422); return; }
      const { title, description, body: text } = a;
      if (!optStr(title) || !optStr(description) || !optStr(text) || title === '' || description === '' || text === '') { send(res, 422, E422); return; }
      if (!slug) { send(res, 404, E404); return; }
      const j = new Job(W_UPDART, v);
      j.a = { slug, title: title ?? null, description: description ?? null, body: text ?? null };
      write(res, j);
    });
  });

  app.del('/api/articles/:slug', (res, req) => {
    const v = auth(req);
    if (v <= 0) { send(res, 401, E401); return; }
    const slug = decParam(req.getParameter(0));
    if (!slug) { send(res, 404, E404); return; }
    begin(res);
    const j = new Job(W_DELART, v);
    j.a = { slug };
    write(res, j);
  });

  const favorite = (on) => (res, req) => {
    const v = auth(req);
    if (v <= 0) { send(res, 401, E401); return; }
    const slug = decParam(req.getParameter(0));
    if (!slug) { send(res, 404, E404); return; }
    begin(res);
    const j = new Job(on ? W_FAV : W_UNFAV, v);
    j.a = { slug };
    write(res, j);
  };
  app.post('/api/articles/:slug/favorite', favorite(true));
  app.del('/api/articles/:slug/favorite', favorite(false));

  app.get('/api/articles/:slug/comments', (res, req) => {
    const v = auth(req);
    if (v < 0) { send(res, 401, E401); return; }
    const slug = decParam(req.getParameter(0));
    if (!slug) { send(res, 404, E404); return; }
    begin(res);
    const j = new Job(K_COMMENTS, v);
    j.key = slug;
    read(res, j);
  });

  app.post('/api/articles/:slug/comments', (res, req) => {
    const v = auth(req);
    const slug = decParam(req.getParameter(0));
    begin(res);
    readJson(res, (body) => {
      if (v <= 0) { send(res, 401, E401); return; }
      const c = isObj(body) ? body.comment : undefined;
      if (!isObj(c) || !nonEmpty(c.body)) { send(res, 422, E422); return; }
      if (!slug) { send(res, 404, E404); return; }
      const j = new Job(W_NEWCMT, v);
      j.a = { slug, body: c.body };
      write(res, j);
    });
  });

  app.del('/api/articles/:slug/comments/:id', (res, req) => {
    const v = auth(req);
    if (v <= 0) { send(res, 401, E401); return; }
    const slug = decParam(req.getParameter(0));
    const id = num(req.getParameter(1));
    if (!slug || id < 1) { send(res, 404, E404); return; }
    begin(res);
    const j = new Job(W_DELCMT, v);
    j.a = { slug, id };
    write(res, j);
  });

  app.any('/*', (res) => { send(res, 404, E404); });
}

if (cfg.stats) {
  const { performance: perf } = require('perf_hooks');
  let elu = perf.eventLoopUtilization();
  setInterval(() => {
    const e = perf.eventLoopUtilization(elu); elu = perf.eventLoopUtilization();
    console.log(`[http ${threadId}] busy=${(e.utilization * 100).toFixed(0)}% waiting=${waiting.size}`);
  }, 5000).unref();
}

const app = uWS.App();
routes(app);
app.listen(cfg.host, cfg.port, (sock) => {
  if (!sock) { console.error(`[http ${threadId}] cannot listen on ${cfg.host}:${cfg.port}`); process.exit(1); }
  require('worker_threads').parentPort.postMessage({ t: 'ready' });
});
