'use strict';
// A small PostgreSQL v3 wire-protocol client, built for batches:
//  - named prepared statements, parsed once per connection;
//  - binary parameters and binary results (Postgres never formats an integer or a timestamp for us);
//  - a pipeline is any number of Bind/Execute messages and one Sync, sent in one write;
//  - rows are not turned into JS objects: every column is an (offset, length) pair into the receive
//    buffer, and the caller reads integers or copies the UTF-8 bytes straight into a response.
// One pipeline is in flight per connection at a time. The receive buffer (and so every column offset)
// stays valid until release(), so a caller can run several pipelines (phase A, then phase B) and use
// all their rows together.
const net = require('net');
const crypto = require('crypto');

const OID = { int4: 23, int8: 20, text: 25, int8arr: 1016, textarr: 1009, int4arr: 1007 };

function parseUrl(url) {
  const u = new URL(url);
  return {
    host: u.hostname || '127.0.0.1',
    port: +u.port || 5432,
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
    database: decodeURIComponent(u.pathname.slice(1)) || decodeURIComponent(u.username),
  };
}

// ---- outgoing messages -------------------------------------------------------------------------

class WBuf {
  constructor() {
    this.b = Buffer.allocUnsafe(1 << 16);
    this.p = 0;
    this.mark = 0;
    this.pmark = 0;
    this.nparam = 0;
  }
  need(n) {
    if (this.p + n > this.b.length) {
      const nb = Buffer.allocUnsafe(Math.max(this.b.length * 2, this.p + n + 1024));
      this.b.copy(nb, 0, 0, this.p);
      this.b = nb;
    }
  }
  u8(v) { this.need(1); this.b[this.p++] = v; }
  i16(v) { this.need(2); const b = this.b, p = this.p; b[p] = (v >> 8) & 255; b[p + 1] = v & 255; this.p = p + 2; }
  i32(v) {
    this.need(4); const b = this.b, p = this.p;
    b[p] = (v >>> 24) & 255; b[p + 1] = (v >>> 16) & 255; b[p + 2] = (v >>> 8) & 255; b[p + 3] = v & 255;
    this.p = p + 4;
  }
  i32at(at, v) { const b = this.b; b[at] = (v >>> 24) & 255; b[at + 1] = (v >>> 16) & 255; b[at + 2] = (v >>> 8) & 255; b[at + 3] = v & 255; }
  i64(v) { // v: an integer Number (|v| < 2^53)
    const hi = Math.floor(v / 4294967296), lo = v - hi * 4294967296;
    this.i32(hi | 0); this.i32(lo >>> 0);
  }
  str(s) { this.need(s.length * 3); this.p += this.b.utf8Write(s, this.p); }
  cstr(s) { this.str(s); this.u8(0); }
  bytes(buf) { this.need(buf.length); buf.copy(this.b, this.p); this.p += buf.length; }
  begin(type) { this.u8(type); this.mark = this.p; this.i32(0); }
  end() { this.i32at(this.mark, this.p - this.mark); }

  // Bind (unnamed portal) + Execute for a prepared statement; parameters follow via p*() calls.
  bind(stmt, nparams) {
    this.begin(0x42); // 'B'
    this.u8(0); this.cstr(stmt);
    this.i16(1); this.i16(1); // all parameters binary
    this.i16(nparams);
  }
  pnull() { this.i32(-1); }
  pint8(v) { this.i32(8); this.i64(v); }
  ptext(s) { // string param (binary format of text = its UTF-8 bytes)
    const at = this.p; this.i32(0); const st = this.p; this.str(s); this.i32at(at, this.p - st);
  }
  ptextOpt(s) { if (s == null) this.pnull(); else this.ptext(s); }
  pint8arr(arr, n) { // int8[] in binary array format
    if (n === undefined) n = arr.length;
    this.i32(20 + n * 12);
    this.i32(1); this.i32(0); this.i32(OID.int8); this.i32(n); this.i32(1);
    for (let i = 0; i < n; i++) { this.i32(8); this.i64(arr[i]); }
  }
  ptextarr(arr, n) {
    if (n === undefined) n = arr.length;
    const at = this.p; this.i32(0); const st = this.p;
    this.i32(1); this.i32(0); this.i32(OID.text); this.i32(n); this.i32(1);
    for (let i = 0; i < n; i++) {
      const la = this.p; this.i32(0); const ls = this.p; this.str(arr[i]); this.i32at(la, this.p - ls);
    }
    this.i32at(at, this.p - st);
  }
  bindEnd() {
    this.i16(1); this.i16(1); // all results binary
    this.end();
    // Execute, unnamed portal, no row limit
    this.need(10); const b = this.b; let p = this.p;
    b[p] = 0x45; b[p + 1] = 0; b[p + 2] = 0; b[p + 3] = 0; b[p + 4] = 9; b[p + 5] = 0;
    b[p + 6] = 0; b[p + 7] = 0; b[p + 8] = 0; b[p + 9] = 0;
    this.p = p + 10;
  }
  sync() { this.need(5); const b = this.b, p = this.p; b[p] = 0x53; b[p + 1] = 0; b[p + 2] = 0; b[p + 3] = 0; b[p + 4] = 4; this.p = p + 5; }
  take() { const out = Buffer.allocUnsafe(this.p); this.b.copy(out, 0, 0, this.p); this.p = 0; return out; }
}

class PgError extends Error {
  constructor(fields) {
    super(fields.M || 'postgres error');
    this.code = fields.C || '';
    this.detail = fields.D;
  }
}

function parseFields(b, p, end) {
  const f = {};
  while (p < end && b[p] !== 0) {
    const t = String.fromCharCode(b[p]);
    let q = p + 1;
    while (q < end && b[q] !== 0) q++;
    f[t] = b.toString('utf8', p + 1, q);
    p = q + 1;
  }
  return f;
}

// ---- connection --------------------------------------------------------------------------------

class Conn {
  constructor(cfg, gucs) {
    this.cfg = cfg;
    this.gucs = gucs || {};
    this.w = new WBuf();
    this.sock = null;
    this.dead = false;
    this.onDead = null;
    // receive buffer: kept (never compacted) until release()
    this.rb = Buffer.allocUnsafe(1 << 20);
    this.rlen = 0;
    this.rpos = 0;
    // row table: row r has its columns at col index rowCol[r] .. ; colOff/colLen per column (len -1 = NULL)
    this.rowCol = new Int32Array(1 << 14);
    this.nrows = 0;
    this.colOff = new Int32Array(1 << 16);
    this.colLen = new Int32Array(1 << 16);
    this.ncols = 0;
    // the pipeline in flight
    this.cb = null;
    this.resFirst = null; // first row of each result
    this.resCount = null; // rows of each result
    this.resErr = null; // PgError of each result (null if ok)
    this.resN = 0; // results expected
    this.resI = 0; // current result
    this.failed = null; // first error of this pipeline
    this.startup = null; // during connect
  }

  connect() {
    return new Promise((resolve, reject) => {
      const s = net.connect({ host: this.cfg.host, port: this.cfg.port });
      this.sock = s;
      s.setNoDelay(true);
      let done = false;
      this.startup = { resolve: (v) => { done = true; resolve(v); }, reject: (e) => { done = true; reject(e); }, scram: null };
      s.on('connect', () => {
        const w = this.w;
        const at = w.p; w.i32(0); w.i32(196608);
        const params = Object.assign({ user: this.cfg.user, database: this.cfg.database, client_encoding: 'UTF8', application_name: 'conduit-node' }, this.gucs);
        for (const k in params) { w.cstr(k); w.cstr(String(params[k])); }
        w.u8(0);
        w.i32at(at, w.p - at);
        s.write(w.take());
      });
      s.on('data', (chunk) => this.onData(chunk));
      const fail = (err) => {
        if (this.dead) return;
        this.dead = true;
        if (!done) this.startup.reject(err || new Error('connection closed'));
        const cb = this.cb; this.cb = null;
        if (cb) cb(err || new Error('connection closed'), null);
        if (this.onDead) this.onDead(err);
      };
      s.on('error', fail);
      s.on('close', () => fail(new Error('postgres connection closed')));
    });
  }

  onData(chunk) {
    const n = chunk.length;
    if (this.rlen + n > this.rb.length) {
      const nb = Buffer.allocUnsafe(Math.max(this.rb.length * 2, this.rlen + n));
      this.rb.copy(nb, 0, 0, this.rlen);
      this.rb = nb;
    }
    chunk.copy(this.rb, this.rlen);
    this.rlen += n;
    this.parse();
  }

  growRows() { const a = new Int32Array(this.rowCol.length * 2); a.set(this.rowCol); this.rowCol = a; }
  growCols(need) {
    let n = this.colOff.length * 2; while (n < need) n *= 2;
    const a = new Int32Array(n); a.set(this.colOff); this.colOff = a;
    const c = new Int32Array(n); c.set(this.colLen); this.colLen = c;
  }

  parse() {
    const b = this.rb;
    let p = this.rpos;
    const end = this.rlen;
    while (end - p >= 5) {
      const type = b[p];
      const len = ((b[p + 1] << 24) | (b[p + 2] << 16) | (b[p + 3] << 8) | b[p + 4]);
      const next = p + 1 + len;
      if (next > end) break;
      const body = p + 5;
      if (type === 0x44) { // DataRow
        let q = body;
        const nc = (b[q] << 8) | b[q + 1];
        q += 2;
        if (this.nrows >= this.rowCol.length) this.growRows();
        if (this.ncols + nc > this.colOff.length) this.growCols(this.ncols + nc);
        this.rowCol[this.nrows++] = this.ncols;
        const co = this.colOff, cl = this.colLen;
        let ci = this.ncols;
        for (let i = 0; i < nc; i++) {
          const l = ((b[q] << 24) | (b[q + 1] << 16) | (b[q + 2] << 8) | b[q + 3]);
          q += 4;
          co[ci] = q; cl[ci] = l; ci++;
          if (l > 0) q += l;
        }
        this.ncols = ci;
      } else if (type === 0x43) { // CommandComplete
        if (this.resI < this.resN) {
          this.resCount[this.resI] = this.nrows - this.resFirst[this.resI];
          this.resI++;
          if (this.resI < this.resN) this.resFirst[this.resI] = this.nrows;
        }
      } else if (type === 0x5a) { // ReadyForQuery
        this.rpos = next;
        if (this.startup) { const st = this.startup; this.startup = null; st.resolve(); }
        else {
          const cb = this.cb; this.cb = null;
          if (cb) cb(null, this);
        }
        // the callback may have released the buffer or sent a new pipeline
        if (this.rpos !== next) return;
        p = next;
        continue;
      } else if (type === 0x45) { // ErrorResponse
        const err = new PgError(parseFields(b, body, next));
        if (this.startup) { this.rpos = next; const st = this.startup; this.startup = null; st.reject(err); this.sock.destroy(); return; }
        if (this.resI < this.resN) {
          this.resErr[this.resI] = err;
          this.resCount[this.resI] = this.nrows - this.resFirst[this.resI];
          // the rest of the pipeline is skipped until Sync
          for (let i = this.resI + 1; i < this.resN; i++) { this.resFirst[i] = this.nrows; this.resCount[i] = 0; this.resErr[i] = err; }
          this.resI = this.resN;
        }
        if (!this.failed) this.failed = err;
      } else if (type === 0x52) { // Authentication
        this.auth(b, body, next);
      }
      // 1 ParseComplete, 2 BindComplete, n NoData, s PortalSuspended, I EmptyQuery, N Notice,
      // S ParameterStatus, K BackendKeyData, A Notification, 3 CloseComplete: nothing to do
      p = next;
    }
    this.rpos = p;
    if (p === end && !this.cb && !this.startup && this.nrows === 0) { this.rpos = 0; this.rlen = 0; }
  }

  auth(b, p, end) {
    const code = ((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]);
    const w = this.w;
    const pw = this.cfg.password;
    if (code === 0) return;
    if (code === 3) { // cleartext
      w.begin(0x70); w.cstr(pw); w.end(); this.sock.write(w.take());
    } else if (code === 5) { // md5
      const salt = b.subarray(p + 4, p + 8);
      const inner = crypto.createHash('md5').update(pw + this.cfg.user).digest('hex');
      const outer = crypto.createHash('md5').update(Buffer.concat([Buffer.from(inner), salt])).digest('hex');
      w.begin(0x70); w.cstr('md5' + outer); w.end(); this.sock.write(w.take());
    } else if (code === 10) { // SASL: SCRAM-SHA-256
      const nonce = crypto.randomBytes(18).toString('base64');
      const first = 'n=*,r=' + nonce;
      this.startup.scram = { nonce, first };
      const data = Buffer.from('n,,' + first);
      w.begin(0x70); w.cstr('SCRAM-SHA-256'); w.i32(data.length); w.bytes(data); w.end();
      this.sock.write(w.take());
    } else if (code === 11) { // SASLContinue
      const sc = this.startup.scram;
      const server = b.toString('utf8', p + 4, end);
      const attrs = {};
      for (const kv of server.split(',')) attrs[kv[0]] = kv.slice(2);
      if (!attrs.r || !attrs.r.startsWith(sc.nonce)) throw new Error('SCRAM nonce mismatch');
      const salted = crypto.pbkdf2Sync(pw, Buffer.from(attrs.s, 'base64'), +attrs.i, 32, 'sha256');
      const clientKey = crypto.createHmac('sha256', salted).update('Client Key').digest();
      const storedKey = crypto.createHash('sha256').update(clientKey).digest();
      const finalNoProof = 'c=biws,r=' + attrs.r;
      const authMsg = sc.first + ',' + server + ',' + finalNoProof;
      const sig = crypto.createHmac('sha256', storedKey).update(authMsg).digest();
      for (let i = 0; i < 32; i++) clientKey[i] ^= sig[i];
      const serverKey = crypto.createHmac('sha256', salted).update('Server Key').digest();
      sc.expect = crypto.createHmac('sha256', serverKey).update(authMsg).digest('base64');
      w.begin(0x70); w.str(finalNoProof + ',p=' + clientKey.toString('base64')); w.end();
      this.sock.write(w.take());
    } else if (code === 12) { // SASLFinal
      const v = b.toString('utf8', p + 4, end);
      if (v.slice(2) !== this.startup.scram.expect) { this.startup.reject(new Error('SCRAM server signature mismatch')); this.sock.destroy(); }
    } else {
      this.startup.reject(new Error('unsupported auth method ' + code));
      this.sock.destroy();
    }
  }

  // Sends what the caller wrote into this.w (Bind/Execute pairs, nres of them) plus a Sync.
  // cb(err, conn) runs at ReadyForQuery; per-result errors are in resErr (err is only a dead connection).
  send(nres, cb) {
    if (this.dead) { this.w.p = 0; cb(new Error('postgres connection is down'), null); return; }
    this.w.sync();
    this.resN = nres;
    this.resI = 0;
    if (!this.resFirst || this.resFirst.length < nres + 1) {
      const n = Math.max(nres + 1, 64);
      this.resFirst = new Int32Array(n); this.resCount = new Int32Array(n); this.resErr = new Array(n);
    }
    for (let i = 0; i < nres; i++) this.resErr[i] = null;
    this.resFirst[0] = this.nrows;
    this.failed = null;
    this.cb = cb;
    this.sock.write(this.w.take());
  }

  // Snapshot of the current pipeline's result ranges (so a later pipeline can reuse the arrays).
  results(n) {
    return { first: this.resFirst.slice(0, n), count: this.resCount.slice(0, n), err: this.resErr.slice(0, n) };
  }

  // Forget every row: all column offsets become invalid.
  release() {
    this.nrows = 0;
    this.ncols = 0;
    if (this.rpos === this.rlen) { this.rpos = 0; this.rlen = 0; }
    else { // should not happen with one pipeline in flight, but keep any partial message
      this.rb.copy(this.rb, 0, this.rpos, this.rlen); this.rlen -= this.rpos; this.rpos = 0;
    }
  }

  // Parse every statement once (named), in one round trip.
  prepare(stmts) {
    return new Promise((resolve, reject) => {
      const w = this.w;
      for (const s of stmts) {
        w.begin(0x50); w.cstr(s.name); w.cstr(s.sql);
        w.i16(s.types.length); for (const t of s.types) w.i32(t);
        w.end();
      }
      this.send(0, (err) => {
        if (err) return reject(err);
        if (this.failed) return reject(this.failed);
        this.release();
        resolve();
      });
    });
  }

  // ---- column accessors (c = column index from rowCol[row] + i) ----
  isNull(c) { return this.colLen[c] < 0; }
  i64(c) {
    const b = this.rb, o = this.colOff[c];
    const hi = (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    const lo = ((b[o + 4] << 24) | (b[o + 5] << 16) | (b[o + 6] << 8) | b[o + 7]) >>> 0;
    return hi * 4294967296 + lo;
  }
  i32(c) { const b = this.rb, o = this.colOff[c]; return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]; }
  bool(c) { return this.rb[this.colOff[c]] !== 0; }
  str(c) { const l = this.colLen[c]; if (l < 0) return null; const o = this.colOff[c]; return this.rb.toString('utf8', o, o + l); }
}

module.exports = { Conn, PgError, OID, parseUrl };
