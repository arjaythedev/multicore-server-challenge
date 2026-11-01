'use strict';
// The database thread: one batch planner for the whole server (READ_LANES Postgres read connections), one
// group-commit write connection, and response assembly. The HTTP threads (http.js) send it their requests and get
// back finished response bodies, so every request in a window shares one batch, whichever thread accepted it.
// bcrypt goes to the main thread, which runs it interleaved on its own threads.
const { workerData, parentPort, threadId } = require('worker_threads');
const crypto = require('crypto');
const { Conn, parseUrl } = require('./pg');
const SQL = require('./sql');
const { Out, lit } = require('./out');

const cfg = workerData;
const PG = parseUrl(cfg.databaseUrl);
const READ_LANES = cfg.readLanes;
const WINDOW_MS = cfg.windowMs;
const READ_MAX = cfg.readMax;
const WRITE_MAX = cfg.writeMax;
const IDLE_FLUSH = cfg.idleFlush;
const GUCS = { jit: 'off', plan_cache_mode: 'force_generic_plan', max_parallel_workers_per_gather: '0' };

// tokens issued at login and sign-up (HS256); verification happens on the HTTP threads
const KEY = crypto.createSecretKey(Buffer.from(cfg.jwtSecret, 'utf8'));
const HDR = Buffer.from('{"alg":"HS256","typ":"JWT"}').toString('base64url');
const DAY30 = 30 * 24 * 3600;

function issueToken(id) {
  const now = Math.floor(Date.now() / 1000);
  const data = HDR + '.' + Buffer.from(`{"sub":"${id}","iat":${now},"exp":${now + DAY30}}`).toString('base64url');
  return data + '.' + crypto.createHmac('sha256', KEY).update(data).digest('base64url');
}

const errBody = (m) => lit(`{"errors":{"body":[${JSON.stringify(m)}]}}`);
const E401 = errBody('unauthorized');
const E401_LOGIN = errBody('invalid email or password');
const E403 = errBody('forbidden');
const E404 = errBody('not found');
const E422_TAKEN = errBody('username or email is already taken');
const E500 = errBody('internal error');

// ------------------------------------------------------------------------------------------------
// replies: a request is identified by (HTTP thread, id). Replies for one thread are collected while a batch is
// assembled and go out as one message: [id, status, end offset] triples plus one buffer of bodies (transferred).

const ports = cfg.ports;
const replies = ports.map(() => ({ meta: [], out: new Out(1 << 16) }));
let replyScheduled = false;
function send(res, status, body) {
  if (res.done) return;
  res.done = true;
  const r = replies[res.t];
  const o = r.out;
  o.need(body.length);
  o.b.set(body, o.p);
  o.p += body.length;
  r.meta.push(res.id, status, o.p);
  if (!replyScheduled) { replyScheduled = true; setImmediate(flushReplies); }
}
function flushReplies() {
  replyScheduled = false;
  for (let t = 0; t < replies.length; t++) {
    const r = replies[t];
    if (r.meta.length === 0) continue;
    const meta = Int32Array.from(r.meta);
    const buf = new ArrayBuffer(r.out.p);
    new Uint8Array(buf).set(r.out.b.subarray(0, r.out.p));
    ports[t].postMessage({ meta, buf }, [meta.buffer, buf]);
    r.meta.length = 0;
    r.out.p = 0;
  }
}

// ------------------------------------------------------------------------------------------------
// jobs

const K_TAGS = 0, K_USER = 1, K_LOGIN = 2, K_PROFILE = 3, K_SLUG = 4, K_ID = 5, K_COMMENTS = 6,
  K_GLOBAL = 7, K_TAG = 8, K_AUTHOR = 9, K_FAVORITED = 10, K_FEED = 11;
const W_REGISTER = 0, W_UPDUSER = 1, W_FOLLOW = 2, W_UNFOLLOW = 3, W_FAV = 4, W_UNFAV = 5, W_NEWART = 6,
  W_UPDART = 7, W_DELART = 8, W_NEWCMT = 9, W_DELCMT = 10;

class Job {
  constructor(res, k, v) {
    this.res = res;
    this.k = k; // kind
    this.v = v; // viewer (0 = anonymous)
    this.key = null; // string key (slug, username, email, tag) or number (id)
    this.lim = 0;
    this.off = 0;
    this.i = 0; // phase-A key index
    this.j = 0; // second key index (list pages)
    this.status = 200;
    this.token = null;
    this.a = null; // write payload
    this.st = 0; // response status
    this.p0 = 0; // response body range in the batch buffer
    this.p1 = 0;
    this.body = null; // or a constant body
    this.key2 = null; // login password (Buffer)
    this.handed = false; // answered elsewhere (bcrypt)
  }
}

// distinct keys of one statement in one batch; index + 1 is the k the SQL tags rows with
class Keys {
  constructor() { this.map = new Map(); this.list = []; }
  idx(key) {
    let i = this.map.get(key);
    if (i === undefined) { i = this.list.length; this.map.set(key, i); this.list.push(key); }
    return i;
  }
  get n() { return this.list.length; }
}

// pages of one list kind: count keys and (key, limit, offset) page keys
class ListKeys {
  constructor() { this.count = new Keys(); this.page = new Keys(); this.pkey = []; this.plim = []; this.poff = []; }
  add(key, lim, off) {
    const c = this.count.idx(key);
    const pk = key + '\u0001' + lim + '\u0001' + off;
    const before = this.page.n;
    const p = this.page.idx(pk);
    if (p === before) { this.pkey.push(key); this.plim.push(lim); this.poff.push(off); }
    return [c, p];
  }
}

const M26 = 67108864; // pair key = viewer * 2^26 + other id

// ------------------------------------------------------------------------------------------------
// JSON fragments

const F = {
  userA: lit('{"user":{"email":'), userToken: lit(',"token":'), userName: lit(',"username":'), bio: lit(',"bio":'),
  image: lit(',"image":'), close2: lit('}}'),
  profOpen: lit('{"profile":'), pUser: lit('{"username":'), pFollowing: lit(',"following":'),
  artOpen: lit('{"article":'), aSlug: lit('{"slug":'), aTitle: lit(',"title":'), aDesc: lit(',"description":'),
  aBody: lit(',"body":'), aTags: lit(',"tagList":['), aCreated: lit('],"createdAt":'), aUpdated: lit(',"updatedAt":'),
  aFavd: lit(',"favorited":'), aFavc: lit(',"favoritesCount":'), aAuthor: lit(',"author":'),
  listOpen: lit('{"articles":['), listCount: lit('],"articlesCount":'),
  cmtsOpen: lit('{"comments":['), cmtOpen: lit('{"comment":'), cId: lit('{"id":'), cCreated: lit(',"createdAt":'),
  cUpdated: lit(',"updatedAt":'), cBody: lit(',"body":'), tagsOpen: lit('{"tags":['), arrClose: lit(']}'),
  TRUE: lit('true'), FALSE: lit('false'),
};

function profileObj(o, pg, cu, cb, ci, following) {
  o.lit(F.pUser); o.col(pg, cu);
  o.lit(F.bio); o.col(pg, cb);
  o.lit(F.image); o.col(pg, ci);
  o.lit(F.pFollowing); o.lit(following ? F.TRUE : F.FALSE);
  o.ch(125);
}

function userJson(o, email, token, username, bio, image) { // JS strings
  o.lit(F.userA); o.jstr(email); o.lit(F.userToken); o.jstr(token); o.lit(F.userName); o.jstr(username);
  o.lit(F.bio); o.jstr(bio); o.lit(F.image); o.jstr(image); o.lit(F.close2);
}

function userJsonPg(o, pg, c, ce, cu, cb, ci, token) { // columns of a users row
  o.lit(F.userA); o.col(pg, ce); o.lit(F.userToken); o.jstr(token); o.lit(F.userName); o.col(pg, cu);
  o.lit(F.bio); o.col(pg, cb); o.lit(F.image); o.col(pg, ci); o.lit(F.close2);
}

// ------------------------------------------------------------------------------------------------
// read lanes: the batch planner

const out = new Out(1 << 21);
let tagGen = new Int32Array(4096), tagPos = new Int32Array(4096), gen = 0;

function finishBatch(jobs) {
  // every response body is in out.b now (it may have grown while writing), send them all
  const b = out.b;
  for (let n = 0; n < jobs.length; n++) {
    const j = jobs[n];
    if (j.st === 0) continue; // handed on (login to bcrypt)
    if (j.body !== null) send(j.res, j.st, j.body);
    else send(j.res, j.st, b.subarray(j.p0, j.p1));
  }
  out.p = 0;
}

function sortByIdDesc(pg, rows) { // rows of article rows (id in column 1), newest first
  if (rows.length < 2) return;
  rows.sort((x, y) => pg.i64(pg.rowCol[y] + 1) - pg.i64(pg.rowCol[x] + 1));
}

class ReadLane {
  constructor(planner) {
    this.planner = planner;
    this.conn = null;
  }

  async connect() {
    for (;;) {
      try {
        const c = new Conn(PG, GUCS);
        await c.connect();
        await c.prepare(SQL.read);
        c.onDead = () => { if (this.conn === c) { this.conn = null; setTimeout(() => this.reconnect(), 500); } };
        this.conn = c;
        return;
      } catch (e) {
        console.error(`[db] read connection failed: ${e.message}`);
        await new Promise((r) => setTimeout(r, 1000));
      }
    }
  }

  async reconnect() { await this.connect(); this.planner.laneFree(this); }

  fail(jobs, err) {
    console.error(`[db] read batch failed: ${err && err.message}`);
    for (const j of jobs) if (!j.handed) { j.st = 500; j.body = E500; }
    finishBatch(jobs);
    if (this.conn) this.conn.release();
    if (this.conn && !this.conn.dead) this.planner.laneFree(this);
  }

  run(jobs) {
    const pg = this.conn;
    if (!pg) { this.fail(jobs, new Error('no connection')); return; }
    if (cfg.stats) { stats.batches++; stats.jobs += jobs.length; if (jobs.length > stats.maxBatch) stats.maxBatch = jobs.length; this.t0 = performance.now(); }
    // ---- distinct keys ----
    let wantTags = false;
    const uid = new Keys(), uemail = new Keys(), prof = new Keys(), aslug = new Keys(), aid = new Keys(), cmts = new Keys(),
      global = new Keys(), feedC = new Keys(), feedP = new Keys();
    const gLim = [], gOff = [], fpV = [], fpLim = [], fpOff = [];
    const lists = [null, null, null];
    for (let n = 0; n < jobs.length; n++) {
      const j = jobs[n];
      switch (j.k) {
        case K_TAGS: wantTags = true; break;
        case K_USER: j.i = uid.idx(j.v); break;
        case K_LOGIN: j.i = uemail.idx(j.key); break;
        case K_PROFILE: j.i = prof.idx(j.key); break;
        case K_SLUG: j.i = aslug.idx(j.key); break;
        case K_ID: j.i = aid.idx(j.key); break;
        case K_COMMENTS: j.i = cmts.idx(j.key); break;
        case K_GLOBAL: {
          const before = global.n;
          j.i = global.idx(j.lim * 1e9 + j.off);
          if (j.i === before) { gLim.push(j.lim); gOff.push(j.off); }
          break;
        }
        case K_TAG: case K_AUTHOR: case K_FAVORITED: {
          const f = j.k - K_TAG;
          const l = lists[f] || (lists[f] = new ListKeys());
          const [c, p] = l.add(j.key, j.lim, j.off);
          j.i = c; j.j = p;
          break;
        }
        case K_FEED: {
          j.i = feedC.idx(j.v);
          const before = feedP.n;
          j.j = feedP.idx(j.v + '\u0001' + j.lim + '\u0001' + j.off);
          if (j.j === before) { fpV.push(j.v); fpLim.push(j.lim); fpOff.push(j.off); }
          break;
        }
      }
    }

    // ---- phase A ----
    const w = pg.w;
    let n = 0;
    const sTags = wantTags ? n++ : -1;
    if (sTags >= 0) { w.bind('tags', 0); w.bindEnd(); }
    const sUid = uid.n ? n++ : -1;
    if (sUid >= 0) { w.bind('uid', 1); w.pint8arr(uid.list); w.bindEnd(); }
    const sEmail = uemail.n ? n++ : -1;
    if (sEmail >= 0) { w.bind('uemail', 1); w.ptextarr(uemail.list); w.bindEnd(); }
    const sProf = prof.n ? n++ : -1;
    if (sProf >= 0) { w.bind('prof', 1); w.ptextarr(prof.list); w.bindEnd(); }
    const sSlug = aslug.n ? n++ : -1;
    if (sSlug >= 0) { w.bind('aslug', 1); w.ptextarr(aslug.list); w.bindEnd(); }
    const sAid = aid.n ? n++ : -1;
    if (sAid >= 0) { w.bind('aid', 1); w.pint8arr(aid.list); w.bindEnd(); }
    const sCmts = cmts.n ? n++ : -1;
    if (sCmts >= 0) { w.bind('cmts', 1); w.ptextarr(cmts.list); w.bindEnd(); }
    const sGlobal = global.n ? n++ : -1;
    if (sGlobal >= 0) { w.bind('global', 2); w.pint8arr(gLim); w.pint8arr(gOff); w.bindEnd(); }
    const sList = [-1, -1, -1];
    const LIST_STMT = ['tag', 'author', 'favlist'];
    for (let f = 0; f < 3; f++) {
      const l = lists[f];
      if (!l) continue;
      sList[f] = n++;
      w.bind(LIST_STMT[f], 4); w.ptextarr(l.count.list); w.ptextarr(l.pkey); w.pint8arr(l.plim); w.pint8arr(l.poff); w.bindEnd();
    }
    const sFeed = feedC.n ? n++ : -1;
    if (sFeed >= 0) { w.bind('feed', 4); w.pint8arr(feedC.list); w.pint8arr(fpV); w.pint8arr(fpLim); w.pint8arr(fpOff); w.bindEnd(); }

    pg.send(n, (err) => {
      if (err) return this.fail(jobs, err);
      if (pg.failed) return this.fail(jobs, pg.failed);
      const ra = pg.results(n);
      try {
        this.phaseB(pg, jobs, ra, { sTags, sUid, sEmail, sProf, sSlug, sAid, sCmts, sGlobal, sList, sFeed, uid, uemail, prof, aslug, aid, cmts, global, feedC, feedP, lists });
      } catch (e) {
        this.fail(jobs, e);
      }
    });
  }

  phaseB(pg, jobs, ra, A) {
    const rowCol = pg.rowCol;
    // ---- decode phase A ----
    const firstRow = (slot, nkeys) => { // k -> row (one row per key)
      const v = new Int32Array(nkeys).fill(-1);
      if (slot < 0) return v;
      for (let r = ra.first[slot], e = r + ra.count[slot]; r < e; r++) {
        const k = pg.i64(rowCol[r]);
        if (k >= 1 && k <= nkeys) v[k - 1] = r;
      }
      return v;
    };
    const userRow = firstRow(A.sUid, A.uid.n);
    const emailRow = firstRow(A.sEmail, A.uemail.n);
    const profRow = firstRow(A.sProf, A.prof.n);
    const slugRow = firstRow(A.sSlug, A.aslug.n);
    const idRow = firstRow(A.sAid, A.aid.n);
    let cmtRows = null;
    if (A.sCmts >= 0) {
      cmtRows = new Array(A.cmts.n);
      for (let i = 0; i < cmtRows.length; i++) cmtRows[i] = null;
      for (let r = ra.first[A.sCmts], e = r + ra.count[A.sCmts]; r < e; r++) {
        const k = pg.i64(rowCol[r]);
        if (k < 1 || k > cmtRows.length) continue;
        (cmtRows[k - 1] || (cmtRows[k - 1] = [])).push(r);
      }
    }
    // list statements: k <= 0 -> count of key -k (k = 0: the one global count); k > 0 -> page row
    const decodeList = (slot, ncount, npage) => {
      const counts = new Float64Array(Math.max(ncount, 1));
      const pages = new Array(npage);
      for (let i = 0; i < npage; i++) pages[i] = [];
      if (slot >= 0) {
        for (let r = ra.first[slot], e = r + ra.count[slot]; r < e; r++) {
          const c = rowCol[r];
          const k = pg.i64(c);
          if (k <= 0) { const i = k === 0 ? 0 : -k - 1; if (i < counts.length) counts[i] = pg.i64(c + 1); }
          else if (k <= npage) pages[k - 1].push(r);
        }
        for (let i = 0; i < npage; i++) sortByIdDesc(pg, pages[i]);
      }
      return { counts, pages };
    };
    const G = decodeList(A.sGlobal, 1, A.global.n);
    const L = [null, null, null];
    for (let f = 0; f < 3; f++) if (A.lists[f]) L[f] = decodeList(A.sList[f], A.lists[f].count.n, A.lists[f].page.n);
    const FD = decodeList(A.sFeed, A.feedC.n, A.feedP.n);

    // ---- phase B keys: every article referenced, once; the viewer flags asked about ----
    const arts = new Map(); // article id -> index
    const artIds = [], artAuthors = [];
    const favAsk = new Set(), folAsk = new Set();
    const addArt = (r, v) => {
      const c = rowCol[r];
      const id = pg.i64(c + 1), author = pg.i64(c + 2);
      if (!arts.has(id)) { arts.set(id, artIds.length); artIds.push(id); artAuthors.push(author); }
      if (v !== 0) { favAsk.add(v * M26 + id); folAsk.add(v * M26 + author); }
    };
    for (let n = 0; n < jobs.length; n++) {
      const j = jobs[n];
      const v = j.v;
      switch (j.k) {
        case K_SLUG: { const r = slugRow[j.i]; if (r >= 0) addArt(r, v); break; }
        case K_ID: { const r = idRow[j.i]; if (r >= 0) addArt(r, v); break; }
        case K_GLOBAL: for (const r of G.pages[j.i]) addArt(r, v); break;
        case K_TAG: case K_AUTHOR: case K_FAVORITED: for (const r of L[j.k - K_TAG].pages[j.j]) addArt(r, v); break;
        case K_FEED: for (const r of FD.pages[j.j]) addArt(r, v); break;
        case K_COMMENTS:
          if (v !== 0 && cmtRows && cmtRows[j.i]) {
            for (const r of cmtRows[j.i]) { const c = rowCol[r]; if (!pg.isNull(c + 2)) folAsk.add(v * M26 + pg.i64(c + 6)); }
          }
          break;
        case K_PROFILE: if (v !== 0) { const r = profRow[j.i]; if (r >= 0) folAsk.add(v * M26 + pg.i64(rowCol[r] + 1)); } break;
      }
    }

    const ctx = { pg, ra, A, userRow, emailRow, profRow, slugRow, idRow, cmtRows, G, L, FD, arts, rb: null, favSet: null, folSet: null };
    let nb = 0;
    const w = pg.w;
    const sArtx = artIds.length ? nb++ : -1;
    const sTagn = artIds.length ? nb++ : -1;
    if (sArtx >= 0) {
      w.bind('artx', 2); w.pint8arr(artIds); w.pint8arr(artAuthors); w.bindEnd();
      w.bind('tagnames', 1); w.pint8arr(artIds); w.bindEnd();
    }
    const sFlags = favAsk.size + folAsk.size ? nb++ : -1;
    if (sFlags >= 0) {
      const fv = [], fa = [], ov = [], ou = [];
      for (const key of favAsk) { const v = Math.floor(key / M26); fv.push(v); fa.push(key - v * M26); }
      for (const key of folAsk) { const v = Math.floor(key / M26); ov.push(v); ou.push(key - v * M26); }
      w.bind('flags', 4); w.pint8arr(fv); w.pint8arr(fa); w.pint8arr(ov); w.pint8arr(ou); w.bindEnd();
    }
    if (nb === 0) { this.assemble(jobs, ctx, null, -1, -1, -1); return; }
    pg.send(nb, (err) => {
      if (err) return this.fail(jobs, err);
      if (pg.failed) return this.fail(jobs, pg.failed);
      try {
        this.assemble(jobs, ctx, pg.results(nb), sArtx, sTagn, sFlags);
      } catch (e) {
        this.fail(jobs, e);
      }
    });
  }

  assemble(jobs, ctx, rb, sArtx, sTagn, sFlags) {
    const { pg, ra, A } = ctx;
    const rowCol = pg.rowCol;
    // artx rows by article index
    const artRow = new Int32Array(ctx.arts.size).fill(-1);
    if (sArtx >= 0) {
      for (let r = rb.first[sArtx], e = r + rb.count[sArtx]; r < e; r++) {
        const i = ctx.arts.get(pg.i64(rowCol[r]));
        if (i !== undefined) artRow[i] = r;
      }
    }
    // tag id -> position in name order (row of tagnames)
    gen++;
    if (sTagn >= 0) {
      for (let r = rb.first[sTagn], e = r + rb.count[sTagn]; r < e; r++) {
        const id = pg.i32(rowCol[r]);
        if (id >= tagGen.length) {
          let n = tagGen.length; while (n <= id) n *= 2;
          const g = new Int32Array(n); g.set(tagGen); tagGen = g;
          const q = new Int32Array(n); q.set(tagPos); tagPos = q;
        }
        tagGen[id] = gen; tagPos[id] = r;
      }
    }
    const favSet = new Set(), folSet = new Set();
    if (sFlags >= 0) {
      for (let r = rb.first[sFlags], e = r + rb.count[sFlags]; r < e; r++) {
        const c = rowCol[r];
        const key = pg.i64(c + 1) * M26 + pg.i64(c + 2);
        if (pg.i64(c) === 0) favSet.add(key); else folSet.add(key);
      }
    }
    const tagRows = [];
    // one Article object from a phase-A article row; false (nothing written) if its author vanished
    const article = (r, full, v) => {
      const c = rowCol[r];
      const id = pg.i64(c + 1), author = pg.i64(c + 2);
      const ai = ctx.arts.get(id);
      const xr = ai === undefined ? -1 : artRow[ai];
      if (xr < 0) return false;
      const x = rowCol[xr];
      out.lit(F.aSlug); out.col(pg, c + 3);
      out.lit(F.aTitle); out.col(pg, c + 4);
      out.lit(F.aDesc); out.col(pg, c + 5);
      if (full) { out.lit(F.aBody); out.col(pg, c + 8); }
      out.lit(F.aTags);
      // tag ids (int4[]), in name order
      if (pg.colLen[x + 1] > 12) {
        const b = pg.rb;
        let o = pg.colOff[x + 1];
        const nd = (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
        if (nd === 1) {
          const cnt = (b[o + 12] << 24) | (b[o + 13] << 16) | (b[o + 14] << 8) | b[o + 15];
          o += 20;
          tagRows.length = 0;
          for (let t = 0; t < cnt; t++) {
            const tid = (b[o + 4] << 24) | (b[o + 5] << 16) | (b[o + 6] << 8) | b[o + 7];
            o += 8;
            if (tid < tagGen.length && tagGen[tid] === gen) tagRows.push(tagPos[tid]);
          }
          if (tagRows.length > 1) tagRows.sort((p, q) => p - q);
          for (let t = 0; t < tagRows.length; t++) {
            if (t > 0) out.ch(44);
            out.col(pg, rowCol[tagRows[t]] + 1);
          }
        }
      }
      out.lit(F.aCreated); out.ts(pg.i64(c + 6));
      out.lit(F.aUpdated); out.ts(pg.i64(c + 7));
      out.lit(F.aFavd); out.lit(v !== 0 && favSet.has(v * M26 + id) ? F.TRUE : F.FALSE);
      out.lit(F.aFavc); out.int(pg.i64(x + 2));
      out.lit(F.aAuthor);
      profileObj(out, pg, x + 3, x + 4, x + 5, v !== 0 && folSet.has(v * M26 + author));
      out.ch(125);
      return true;
    };
    const list = (j, rows, count) => {
      j.p0 = out.p;
      out.lit(F.listOpen);
      let first = true;
      for (let i = 0; i < rows.length; i++) {
        const mark = out.p;
        if (!first) out.ch(44);
        if (article(rows[i], false, j.v)) first = false; else out.p = mark;
      }
      out.lit(F.listCount); out.int(count); out.ch(125);
      j.p1 = out.p; j.st = 200;
    };

    for (let n = 0; n < jobs.length; n++) {
      const j = jobs[n];
      const v = j.v;
      switch (j.k) {
        case K_TAGS: {
          j.p0 = out.p;
          out.lit(F.tagsOpen);
          const r = ra.first[A.sTags];
          if (ra.count[A.sTags] > 0 && !pg.isNull(rowCol[r])) {
            const b = pg.rb;
            let o = pg.colOff[rowCol[r]];
            const nd = (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
            if (nd === 1) {
              const cnt = (b[o + 12] << 24) | (b[o + 13] << 16) | (b[o + 14] << 8) | b[o + 15];
              o += 20;
              for (let t = 0; t < cnt; t++) {
                const l = (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
                o += 4;
                if (t > 0) out.ch(44);
                out.bstr(b, o, l);
                o += l;
              }
            }
          }
          out.lit(F.arrClose);
          j.p1 = out.p; j.st = 200;
          break;
        }
        case K_USER: {
          const r = ctx.userRow[j.i];
          if (r < 0) { j.st = 401; j.body = E401; break; }
          const c = rowCol[r];
          j.p0 = out.p;
          userJsonPg(out, pg, c, c + 3, c + 2, c + 4, c + 5, j.token);
          j.p1 = out.p; j.st = 200;
          break;
        }
        case K_LOGIN: {
          const r = ctx.emailRow[j.i];
          if (r < 0) { j.st = 401; j.body = E401_LOGIN; break; }
          const c = rowCol[r];
          const user = { id: pg.i64(c + 1), username: pg.str(c + 2), email: pg.str(c + 3), bio: pg.str(c + 4), image: pg.str(c + 5) };
          const hash = pg.str(c + 6);
          j.st = 0; // answered after bcrypt
          j.handed = true;
          loginVerify(j, user, hash);
          break;
        }
        case K_PROFILE: {
          const r = ctx.profRow[j.i];
          if (r < 0) { j.st = 404; j.body = E404; break; }
          const c = rowCol[r];
          j.p0 = out.p;
          out.lit(F.profOpen);
          profileObj(out, pg, c + 2, c + 3, c + 4, v !== 0 && folSet.has(v * M26 + pg.i64(c + 1)));
          out.ch(125);
          j.p1 = out.p; j.st = 200;
          break;
        }
        case K_SLUG: case K_ID: {
          const r = j.k === K_SLUG ? ctx.slugRow[j.i] : ctx.idRow[j.i];
          j.p0 = out.p;
          out.lit(F.artOpen);
          if (r >= 0 && article(r, true, v)) { out.ch(125); j.p1 = out.p; j.st = j.status; }
          else { out.p = j.p0; j.st = 404; j.body = E404; }
          break;
        }
        case K_COMMENTS: {
          const rows = ctx.cmtRows && ctx.cmtRows[j.i];
          if (!rows) { j.st = 404; j.body = E404; break; }
          const list = [];
          for (const r of rows) { const c = rowCol[r]; if (!pg.isNull(c + 2) && !pg.isNull(c + 7)) list.push(r); }
          if (list.length > 1) {
            list.sort((x, y) => {
              const cx = rowCol[x], cy = rowCol[y];
              return (pg.i64(cy + 4) - pg.i64(cx + 4)) || (pg.i64(cy + 2) - pg.i64(cx + 2));
            });
          }
          j.p0 = out.p;
          out.lit(F.cmtsOpen);
          for (let i = 0; i < list.length; i++) {
            const c = rowCol[list[i]];
            if (i > 0) out.ch(44);
            out.lit(F.cId); out.int(pg.i64(c + 2));
            out.lit(F.cCreated); out.ts(pg.i64(c + 4));
            out.lit(F.cUpdated); out.ts(pg.i64(c + 5));
            out.lit(F.cBody); out.col(pg, c + 3);
            out.lit(F.aAuthor);
            profileObj(out, pg, c + 7, c + 8, c + 9, v !== 0 && folSet.has(v * M26 + pg.i64(c + 6)));
            out.ch(125);
          }
          out.lit(F.arrClose);
          j.p1 = out.p; j.st = 200;
          break;
        }
        case K_GLOBAL: list(j, ctx.G.pages[j.i], ctx.G.counts[0]); break;
        case K_TAG: case K_AUTHOR: case K_FAVORITED: {
          const D = ctx.L[j.k - K_TAG];
          list(j, D.pages[j.j], D.counts[j.i]);
          break;
        }
        case K_FEED: list(j, ctx.FD.pages[j.j], ctx.FD.counts[j.i]); break;
      }
    }
    finishBatch(jobs);
    pg.release();
    if (cfg.stats) stats.pgms += performance.now() - this.t0;
    this.planner.laneFree(this);
  }
}

// The batch clock: the first read to arrive opens a window; when it closes, everything waiting goes to a free
// lane as one batch. Lanes take turns, so while one batch runs in Postgres the next one is being collected.
class Planner {
  constructor() {
    this.q = [];
    this.free = [];
    this.lanes = [];
    this.timer = null;
    this.due = false; // the window has closed and the batch waits for a lane
    this.busy = 0;
    this.fire = () => { this.timer = null; this.due = true; this.dispatch(); };
  }
  async start(n) {
    for (let i = 0; i < n; i++) { const l = new ReadLane(this); this.lanes.push(l); }
    await Promise.all(this.lanes.map((l) => l.connect()));
    this.free = this.lanes.slice();
  }
  push(job) {
    this.q.push(job);
    if (this.timer || this.due) return;
    if (IDLE_FLUSH && this.busy === 0) { this.due = true; setImmediate(() => this.dispatch()); return; }
    this.timer = setTimeout(this.fire, WINDOW_MS);
  }
  dispatch() {
    if (!this.due || this.q.length === 0) { this.due = false; return; }
    const lane = this.free.pop();
    if (!lane) return; // laneFree() dispatches
    this.due = false;
    let batch;
    if (this.q.length > READ_MAX) batch = this.q.splice(0, READ_MAX);
    else { batch = this.q; this.q = []; }
    // a request whose client is gone (timed out, closed) is not worth a Postgres round trip
    let k = 0;
    for (let i = 0; i < batch.length; i++) if (!batch[i].res.aborted) batch[k++] = batch[i];
    batch.length = k;
    if (k === 0) { this.free.push(lane); if (this.q.length) { this.due = true; this.dispatch(); } return; }
    this.busy++;
    lane.run(batch);
    if (this.q.length) { this.due = true; this.dispatch(); }
  }
  laneFree(lane) {
    this.busy = Math.max(0, this.busy - 1);
    if (!this.free.includes(lane)) this.free.push(lane);
    if (this.due) this.dispatch();
  }
}

// ------------------------------------------------------------------------------------------------
// the write lane: group commit. Every write waiting while the previous group commits goes out as one implicit
// transaction (all Bind/Execute messages before one Sync); responses are released after its ReadyForQuery,
// i.e. after COMMIT. If any statement fails the whole group rolls back and each write is retried on its own.

class WriteLane {
  constructor(planner) {
    this.planner = planner;
    this.conn = null;
    this.q = [];
    this.busy = false;
  }
  async connect() {
    for (;;) {
      try {
        const c = new Conn(PG, { jit: 'off' });
        await c.connect();
        await c.prepare(SQL.write);
        c.onDead = () => { if (this.conn === c) { this.conn = null; setTimeout(() => this.reconnect(), 500); } };
        this.conn = c;
        return;
      } catch (e) {
        console.error(`[db] write connection failed: ${e.message}`);
        await new Promise((r) => setTimeout(r, 1000));
      }
    }
  }
  async reconnect() { await this.connect(); this.busy = false; this.pump(); }
  push(job) { this.q.push(job); if (!this.busy) this.pump(); }
  pump() {
    if (this.busy || this.q.length === 0 || !this.conn) return;
    // a profile update can fail by design (unique violation), so it never shares a transaction
    let group;
    if (this.q[0].k === W_UPDUSER) group = this.q.splice(0, 1);
    else {
      let n = 0;
      while (n < this.q.length && n < WRITE_MAX && this.q[n].k !== W_UPDUSER) n++;
      group = this.q.splice(0, n);
    }
    this.run(group, true);
  }
  bind(w, j) { // returns the number of statements
    const a = j.a, v = j.v;
    switch (j.k) {
      case W_REGISTER: w.bind('register', 3); w.ptext(a.username); w.ptext(a.email); w.ptext(a.hash); w.bindEnd(); return 1;
      case W_UPDUSER:
        w.bind('upduser', 6); w.pint8(v); w.ptextOpt(a.email); w.ptextOpt(a.username); w.ptextOpt(a.hash); w.ptextOpt(a.bio); w.ptextOpt(a.image); w.bindEnd(); return 1;
      case W_FOLLOW: w.bind('follow', 2); w.pint8(v); w.ptext(a.username); w.bindEnd(); return 1;
      case W_UNFOLLOW: w.bind('unfollow', 2); w.pint8(v); w.ptext(a.username); w.bindEnd(); return 1;
      case W_FAV: w.bind('fav', 2); w.pint8(v); w.ptext(a.slug); w.bindEnd(); return 1;
      case W_UNFAV: w.bind('unfav', 2); w.pint8(v); w.ptext(a.slug); w.bindEnd(); return 1;
      case W_NEWART:
        w.bind('newart', 4); w.pint8(v); w.ptext(a.title); w.ptext(a.description); w.ptext(a.body); w.bindEnd();
        if (a.tags.length === 0) return 1;
        w.bind('newtags', 1); w.ptextarr(a.tags); w.bindEnd();
        w.bind('arttags', 1); w.ptextarr(a.tags); w.bindEnd();
        return 3;
      case W_UPDART:
        w.bind('updart', 5); w.ptext(a.slug); w.ptextOpt(a.title); w.ptextOpt(a.description); w.ptextOpt(a.body); w.pint8(v); w.bindEnd(); return 1;
      case W_DELART: w.bind('delart', 2); w.ptext(a.slug); w.pint8(v); w.bindEnd(); return 1;
      case W_NEWCMT: w.bind('newcmt', 3); w.ptext(a.slug); w.pint8(v); w.ptext(a.body); w.bindEnd(); return 1;
      case W_DELCMT: w.bind('delcmt', 3); w.pint8(a.id); w.ptext(a.slug); w.pint8(v); w.bindEnd(); return 1;
    }
    return 0;
  }
  run(group, grouped) {
    this.busy = true;
    if (cfg.stats) { stats.groups++; stats.writes += group.length; }
    const pg = this.conn;
    const w = pg.w;
    const spans = new Int32Array(group.length);
    let n = 0;
    for (let i = 0; i < group.length; i++) { spans[i] = n; n += this.bind(w, group[i]); }
    pg.send(n, (err) => {
      if (err) { // connection lost: the commit outcome is unknown, so nothing is retried
        console.error(`[db] write group failed: ${err.message}`);
        for (const j of group) send(j.res, 500, E500);
        return; // reconnect() resumes
      }
      if (pg.failed && group.length > 1) {
        // the group rolled back: run each write on its own
        pg.release();
        const rest = group.slice();
        const next = () => {
          const j = rest.shift();
          if (!j) { this.busy = false; this.pump(); return; }
          this.runOne(j, next);
        };
        next();
        return;
      }
      const ra = pg.results(n);
      for (let i = 0; i < group.length; i++) this.finish(group[i], pg, ra, spans[i]);
      finishWrites(group);
      pg.release();
      this.busy = false;
      this.pump();
    });
  }
  runOne(j, done) {
    const pg = this.conn;
    if (!pg) { send(j.res, 500, E500); done(); return; }
    const n = this.bind(pg.w, j);
    pg.send(n, (err) => {
      if (err) { send(j.res, 500, E500); done(); return; }
      const ra = pg.results(n);
      this.finish(j, pg, ra, 0);
      finishWrites([j]);
      pg.release();
      done();
    });
  }
  finish(j, pg, ra, s) {
    let e = null;
    for (let i = s; i < ra.err.length && i < s + (j.k === W_NEWART && j.a.tags.length ? 3 : 1); i++) if (ra.err[i]) { e = ra.err[i]; break; }
    if (e) {
      if (e.code === '23505') { j.st = 422; j.body = E422_TAKEN; }
      else { console.error(`[db] write failed: ${e.code} ${e.message}`); j.st = 500; j.body = E500; }
      return;
    }
    const has = ra.count[s] > 0;
    const c = has ? pg.rowCol[ra.first[s]] : -1;
    const v = j.v;
    switch (j.k) {
      case W_REGISTER:
        if (!has) { j.st = 422; j.body = E422_TAKEN; return; }
        j.p0 = out.p; userJsonPg(out, pg, c, c + 2, c + 1, c + 3, c + 4, issueToken(pg.i64(c))); j.p1 = out.p; j.st = 201; return;
      case W_UPDUSER:
        if (!has) { j.st = 401; j.body = E401; return; }
        j.p0 = out.p; userJsonPg(out, pg, c, c + 2, c + 1, c + 3, c + 4, j.token); j.p1 = out.p; j.st = 200; return;
      case W_FOLLOW: case W_UNFOLLOW:
        if (!has) { j.st = 404; j.body = E404; return; }
        j.p0 = out.p; out.lit(F.profOpen); profileObj(out, pg, c, c + 1, c + 2, j.k === W_FOLLOW); out.ch(125); j.p1 = out.p; j.st = 200; return;
      case W_FAV: case W_UNFAV: case W_NEWART:
        if (!has) { j.st = j.k === W_NEWART ? 500 : 404; j.body = j.k === W_NEWART ? E500 : E404; return; }
        this.readBack(j, pg.i64(c), j.k === W_NEWART ? 201 : 200); return;
      case W_UPDART:
        if (!has) { j.st = 404; j.body = E404; return; }
        if (pg.i64(c + 1) !== v) { j.st = 403; j.body = E403; return; }
        this.readBack(j, pg.i64(c), 200); return;
      case W_DELART: case W_DELCMT:
        if (!has) { j.st = 404; j.body = E404; return; }
        if (pg.i64(c) !== v) { j.st = 403; j.body = E403; return; }
        j.st = 204; j.body = EMPTY; return;
      case W_NEWCMT:
        if (!has) { j.st = 404; j.body = E404; return; }
        j.p0 = out.p;
        out.lit(F.cmtOpen); out.lit(F.cId); out.int(pg.i64(c));
        out.lit(F.cCreated); out.ts(pg.i64(c + 2)); out.lit(F.cUpdated); out.ts(pg.i64(c + 3));
        out.lit(F.cBody); out.col(pg, c + 1);
        out.lit(F.aAuthor); profileObj(out, pg, c + 4, c + 5, c + 6, false);
        out.lit(F.close2);
        j.p1 = out.p; j.st = 201; return;
    }
  }
  // the article is read back through the read lanes, after the commit, in a new snapshot
  readBack(j, id, status) {
    j.st = 0;
    const r = new Job(j.res, K_ID, j.v);
    r.key = id; r.status = status;
    this.planner.push(r);
  }
}
const EMPTY = Buffer.alloc(0);

function finishWrites(group) {
  const b = out.b;
  for (const j of group) {
    if (j.st === 0) continue;
    if (j.body !== null) send(j.res, j.st, j.body);
    else send(j.res, j.st, b.subarray(j.p0, j.p1));
  }
  // `out` is shared with the read lanes, but every user of it writes and sends synchronously
  out.p = 0;
}

// ------------------------------------------------------------------------------------------------
// bcrypt (on the main thread's bcrypt workers)

const bcryptWaiting = new Map();
let bcryptSeq = 0;
function bcrypt(password, setting, cb) {
  const id = ++bcryptSeq;
  bcryptWaiting.set(id, cb);
  parentPort.postMessage({ t: 'bcrypt', id, pw: password, setting });
}
parentPort.on('message', (m) => {
  if (m.t === 'bcrypt') {
    const cb = bcryptWaiting.get(m.id);
    bcryptWaiting.delete(m.id);
    if (cb) cb(m.hash);
  }
});
const BF64 = './ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
function newSetting() { // "$2b$10$" + 22 characters of bcrypt base64 from 16 random bytes
  const r = crypto.randomBytes(16);
  let s = '$2b$10$';
  let i = 0;
  while (true) {
    let c1 = r[i++];
    s += BF64[c1 >> 2];
    c1 = (c1 & 3) << 4;
    if (i >= 16) { s += BF64[c1]; break; }
    let c2 = r[i++];
    c1 |= c2 >> 4; s += BF64[c1];
    c1 = (c2 & 15) << 2;
    c2 = r[i++];
    c1 |= c2 >> 6; s += BF64[c1];
    s += BF64[c2 & 63];
  }
  return s;
}
function hashPassword(pw, cb) { bcrypt(Buffer.from(pw, 'utf8'), newSetting(), cb); }

function loginVerify(j, user, hash) {
  const pw = j.key2;
  bcrypt(pw, hash, (got) => {
    if (got !== null && got.length === hash.length && crypto.timingSafeEqual(Buffer.from(got), Buffer.from(hash))) {
      const o = new Out(512);
      userJson(o, user.email, issueToken(user.id), user.username, user.bio, user.image);
      send(j.res, 200, o.b.subarray(0, o.p));
    } else send(j.res, 401, E401_LOGIN);
  });
}


// ------------------------------------------------------------------------------------------------
// requests from the HTTP threads: flat arrays of [id, kind, viewer, key, limit, offset, token, payload] per request;
// write kinds arrive as 100 + W_*

const planner = new Planner();
const writer = new WriteLane(planner);

function startWrite(j) {
  const a = j.a;
  if ((j.k === W_REGISTER || j.k === W_UPDUSER) && typeof a.password === 'string') {
    const pw = a.password;
    a.password = null;
    hashPassword(pw, (h) => { if (!h) { send(j.res, 500, E500); return; } a.hash = h; writer.push(j); });
  } else writer.push(j);
}

function onRequests(t, m) {
  for (let i = 0; i < m.length; i += 8) {
    const res = { t, id: m[i], done: false };
    const k = m[i + 1];
    if (k >= 100) {
      const j = new Job(res, k - 100, m[i + 2]);
      j.token = m[i + 6];
      j.a = m[i + 7];
      startWrite(j);
    } else {
      const j = new Job(res, k, m[i + 2]);
      j.key = m[i + 3]; j.lim = m[i + 4]; j.off = m[i + 5]; j.token = m[i + 6];
      if (k === K_LOGIN) j.key2 = Buffer.from(m[i + 7], 'utf8');
      planner.push(j);
    }
  }
}

// optional diagnostics (STATS=1): event-loop delay and utilization, GC pauses, batch sizes, Postgres round trips
const stats = { batches: 0, jobs: 0, pgms: 0, maxBatch: 0, writes: 0, groups: 0 };
if (cfg.stats) {
  const { monitorEventLoopDelay, PerformanceObserver, performance: perf } = require('perf_hooks');
  const h = monitorEventLoopDelay({ resolution: 5 }); h.enable();
  let gcMs = 0, gcMax = 0, gcN = 0, elu = perf.eventLoopUtilization();
  new PerformanceObserver((l) => { for (const e of l.getEntries()) { gcMs += e.duration; gcN++; if (e.duration > gcMax) gcMax = e.duration; } }).observe({ entryTypes: ['gc'] });
  setInterval(() => {
    const m = process.memoryUsage();
    const e = perf.eventLoopUtilization(elu); elu = perf.eventLoopUtilization();
    console.log(`[db] busy=${(e.utilization * 100).toFixed(0)}% loop p99=${(h.percentile(99) / 1e6).toFixed(1)} max=${(h.max / 1e6).toFixed(1)}ms gc n=${gcN} ${gcMs.toFixed(0)}ms max=${gcMax.toFixed(1)} ` +
      `batches=${stats.batches} avg=${(stats.jobs / Math.max(1, stats.batches)).toFixed(1)} max=${stats.maxBatch} pg=${(stats.pgms / Math.max(1, stats.batches)).toFixed(2)}ms ` +
      `writes=${stats.writes}/${stats.groups} q=${planner.q.length} free=${planner.free.length} heap=${(m.heapUsed / 1e6).toFixed(0)}MB`);
    h.reset(); gcMs = 0; gcMax = 0; gcN = 0;
    stats.batches = stats.jobs = stats.pgms = stats.maxBatch = stats.writes = stats.groups = 0;
  }, 5000).unref();
}

// optional CPU profile of this worker (PROFILE_S=<seconds after PROFILE_DELAY_S>), written to /tmp
if (cfg.profileS > 0) {
  const inspector = require('inspector');
  const fs = require('fs');
  const sess = new inspector.Session();
  sess.connect();
  setTimeout(() => {
    sess.post('Profiler.enable', () => sess.post('Profiler.setSamplingInterval', { interval: 200 }, () => sess.post('Profiler.start', () => {
      setTimeout(() => sess.post('Profiler.stop', (err, { profile }) => {
        fs.writeFileSync(`/tmp/db-${threadId}.cpuprofile`, JSON.stringify(profile));
        console.log(`[w${threadId}] profile written`);
      }), cfg.profileS * 1000);
    })));
  }, cfg.profileDelayS * 1000);
}

async function main() {
  await Promise.all([planner.start(READ_LANES), writer.connect()]);
  ports.forEach((p, t) => p.on('message', (m) => onRequests(t, m)));
  parentPort.postMessage({ t: 'ready' });
}

main().catch((e) => { console.error(e); process.exit(1); });
