'use strict';
// The 19 Conduit endpoints. Validation order follows the reference: auth (401) -> body shape (422) -> database (404/403).
// Request handling is a thin shell: parse, validate, build the parameter list, hand it to the addon, write the
// bytes Postgres produced.

const native = require('../build/conduit.node');
const pg = require('./pg');
const { S } = require('./sql');

const READ = 0;
const WRITE = 1;
const OK = 0;
const NONE = 1;
const BAD = Symbol('bad');
const hasOwn = Object.prototype.hasOwnProperty;
const MAX_INT32 = 2147483647;
const MAX_INT64 = '9223372036854775807';

// ------------------------------------------------------------------ responses

function sendBuf(res, status, buf) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': buf.length });
  res.end(buf);
}
function sendError(res, status, message) {
  sendBuf(res, status, Buffer.from('{"errors":{"body":["' + message + '"]}}'));
}
function sendNoContent(res) {
  res.writeHead(204);
  res.end();
}
const notFound = (res) => sendError(res, 404, 'not found');
const unauthorized = (res) => sendError(res, 401, 'unauthorized');
const unprocessable = (res, msg) => sendError(res, 422, msg);

function dbFailure(res, r) {
  if (r.sqlstate === '23505') return sendError(res, 422, 'already taken');
  console.error('[db] error', r.sqlstate, r.buf ? r.buf.toString() : '');
  return sendError(res, 500, 'internal error');
}

function sendUser(res, status, u, token) {
  sendBuf(res, status, Buffer.from(JSON.stringify({
    user: { email: u.email, token, username: u.username, bio: u.bio, image: u.image },
  })));
}

// ------------------------------------------------------------------ request parsing

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(chunks.length === 1 ? chunks[0] : Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

// Body must be a JSON object holding an object under `key` (case-sensitive). null = invalid.
function bodyObject(buf, key) {
  let top;
  try {
    top = JSON.parse(buf.toString('utf8'));
  } catch {
    return null;
  }
  if (top === null || typeof top !== 'object' || Array.isArray(top) || !hasOwn.call(top, key)) return null;
  const inner = top[key];
  if (inner === null || typeof inner !== 'object' || Array.isArray(inner)) return null;
  return inner;
}

// required, non-empty string; null otherwise
function reqString(m, k) {
  if (!hasOwn.call(m, k)) return null;
  const v = m[k];
  return typeof v === 'string' && v !== '' ? v : null;
}

// optional string: undefined (absent or null) | string | BAD
function optString(m, k, nonEmpty) {
  if (!hasOwn.call(m, k)) return undefined;
  const v = m[k];
  if (v === null) return undefined;
  if (typeof v !== 'string') return BAD;
  if (nonEmpty && v === '') return BAD;
  return v;
}

// bcrypt only uses 72 bytes (and the C implementation stops at a NUL), so refuse anything else.
const passwordFits = (pw) => Buffer.byteLength(pw, 'utf8') <= 72 && pw.indexOf('\u0000') === -1;

function decodeQueryPart(s) {
  if (s.indexOf('%') === -1 && s.indexOf('+') === -1) return s;
  try {
    return decodeURIComponent(s.replace(/\+/g, ' '));
  } catch {
    return null;
  }
}

// first value of each key wins (like Go's url.Values.Get); malformed pairs are dropped
function parseQuery(qs) {
  const out = Object.create(null);
  if (qs === '') return out;
  let start = 0;
  while (start <= qs.length) {
    let amp = qs.indexOf('&', start);
    if (amp === -1) amp = qs.length;
    if (amp > start) {
      const pair = qs.slice(start, amp);
      const eq = pair.indexOf('=');
      const k = decodeQueryPart(eq === -1 ? pair : pair.slice(0, eq));
      const v = decodeQueryPart(eq === -1 ? '' : pair.slice(eq + 1));
      if (k !== null && v !== null && out[k] === undefined) out[k] = v;
    }
    start = amp + 1;
  }
  return out;
}

function isUint(s) {
  if (s.length === 0 || s.length > 19) return false;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 48 || c > 57) return false;
  }
  return s.length < 19 || s <= MAX_INT64;
}

// limit default 20 (1..100), offset default 0 (>= 0); a parameter that is present must be valid. null = 422.
// Offsets beyond int32 give an empty page anyway, so they are clamped.
function limitOffset(q) {
  let limit = 20;
  let offset = 0;
  if (q.limit !== undefined) {
    if (!isUint(q.limit)) return null;
    limit = Number(q.limit);
    if (limit < 1 || limit > 100) return null;
  }
  if (q.offset !== undefined) {
    if (!isUint(q.offset)) return null;
    offset = Math.min(Number(q.offset), MAX_INT32);
  }
  return [limit, offset];
}

// text[] literal for Postgres
function pgArray(items) {
  let s = '{';
  for (let i = 0; i < items.length; i++) {
    if (i > 0) s += ',';
    s += '"' + items[i].replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  }
  return s + '}';
}

function seg(s) {
  if (s === '') return null;
  if (s.indexOf('%') === -1) return s;
  try {
    return decodeURIComponent(s);
  } catch {
    return null;
  }
}

// ------------------------------------------------------------------ auth
// 0 = no header (anonymous), -1 = present but invalid, > 0 = user id. Signature and exp are checked on every call.
function auth(req) {
  const h = req.headers.authorization;
  if (h === undefined || h === '') return 0;
  if (h.length < 7 || !h.startsWith('Token ')) return -1;
  const id = native.jwtVerify(h.slice(6));
  return id > 0 ? id : -1;
}
function requireAuth(req, res) {
  const id = auth(req);
  if (id <= 0) {
    unauthorized(res);
    return 0;
  }
  return id;
}
function optionalAuth(req, res) {
  const id = auth(req);
  if (id < 0) {
    unauthorized(res);
    return -1;
  }
  return id;
}

// ------------------------------------------------------------------ users

async function register(req, res) {
  const m = bodyObject(await readBody(req), 'user');
  if (m === null) return unprocessable(res, 'invalid body');
  const username = reqString(m, 'username');
  const email = reqString(m, 'email');
  const password = reqString(m, 'password');
  if (username === null || email === null || password === null) {
    return unprocessable(res, 'username, email and password are required');
  }
  if (!passwordFits(password)) return unprocessable(res, 'password is too long');
  const hash = await pg.bcryptHash(password);
  if (hash === null) return sendError(res, 500, 'internal error');
  const r = await pg.exec(WRITE, [S.register, 3, username, email, hash]);
  if (r.status !== OK) return dbFailure(res, r);
  const u = JSON.parse(r.buf.toString('utf8'));
  return sendUser(res, 201, u, native.jwtSign(u.id));
}

async function login(req, res) {
  const m = bodyObject(await readBody(req), 'user');
  if (m === null) return unprocessable(res, 'invalid body');
  const email = reqString(m, 'email');
  const password = reqString(m, 'password');
  if (email === null || password === null) return unprocessable(res, 'email and password are required');
  const r = await pg.exec(READ, [S.login, 1, email]);
  if (r.status === NONE) return sendError(res, 401, 'invalid email or password');
  if (r.status !== OK) return dbFailure(res, r);
  if (!passwordFits(password)) return sendError(res, 401, 'invalid email or password');
  const u = JSON.parse(r.buf.toString('utf8'));
  if (!(await pg.bcryptVerify(password, u.hash))) return sendError(res, 401, 'invalid email or password');
  return sendUser(res, 200, u, native.jwtSign(u.id));
}

async function currentUser(req, res) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const r = await pg.exec(READ, [S.userGet, 2, String(viewer), req.headers.authorization.slice(6)]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  if (r.status === NONE) return unauthorized(res);
  return dbFailure(res, r);
}

async function updateUser(req, res) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const m = bodyObject(await readBody(req), 'user');
  if (m === null) return unprocessable(res, 'invalid body');
  const email = optString(m, 'email', true);
  const username = optString(m, 'username', true);
  const password = optString(m, 'password', true);
  const bio = optString(m, 'bio', false);
  const image = optString(m, 'image', false);
  if (email === BAD || username === BAD || password === BAD || bio === BAD || image === BAD) {
    return unprocessable(res, 'invalid user fields');
  }
  let hash = null;
  if (password !== undefined) {
    if (!passwordFits(password)) return unprocessable(res, 'password is too long');
    hash = await pg.bcryptHash(password);
    if (hash === null) return sendError(res, 500, 'internal error');
  }
  const r = await pg.exec(WRITE, [
    S.userUpdate, 7, String(viewer), email ?? null, username ?? null, hash, bio ?? null, image ?? null,
    req.headers.authorization.slice(6),
  ]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  if (r.status === NONE) return unauthorized(res);
  return dbFailure(res, r);
}

// ------------------------------------------------------------------ profiles

async function getProfile(req, res, username) {
  const viewer = optionalAuth(req, res);
  if (viewer < 0) return;
  const r = await pg.exec(READ, [S.profile, 2, String(viewer), username]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  if (r.status === NONE) return notFound(res);
  return dbFailure(res, r);
}

async function follow(req, res, username, on) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const v = String(viewer);
  const r = await pg.exec(WRITE, [on ? S.followIns : S.followDel, 2, v, username, S.profile, 2, v, username]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  if (r.status === NONE) return notFound(res);
  return dbFailure(res, r);
}

// ------------------------------------------------------------------ articles

async function listArticles(req, res, qs) {
  const viewer = optionalAuth(req, res);
  if (viewer < 0) return;
  const q = parseQuery(qs);
  const lo = limitOffset(q);
  if (lo === null) return unprocessable(res, 'limit must be 1-100 and offset >= 0');
  const v = String(viewer);
  let spec;
  // the first non-empty filter in the order tag, author, favorited applies
  if (q.tag !== undefined && q.tag !== '') spec = [S.listTag, 4, v, String(lo[0]), String(lo[1]), q.tag];
  else if (q.author !== undefined && q.author !== '') spec = [S.listAuthor, 4, v, String(lo[0]), String(lo[1]), q.author];
  else if (q.favorited !== undefined && q.favorited !== '') spec = [S.listFavorited, 4, v, String(lo[0]), String(lo[1]), q.favorited];
  else spec = [S.listAll, 3, v, String(lo[0]), String(lo[1])];
  const r = await pg.exec(READ, spec);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  return dbFailure(res, r);
}

async function feed(req, res, qs) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const lo = limitOffset(parseQuery(qs));
  if (lo === null) return unprocessable(res, 'limit must be 1-100 and offset >= 0');
  const r = await pg.exec(READ, [S.feed, 3, String(viewer), String(lo[0]), String(lo[1])]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  return dbFailure(res, r);
}

async function getArticle(req, res, slug) {
  const viewer = optionalAuth(req, res);
  if (viewer < 0) return;
  const r = await pg.exec(READ, [S.articleBySlug, 2, String(viewer), slug]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  if (r.status === NONE) return notFound(res);
  return dbFailure(res, r);
}

async function createArticle(req, res) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const m = bodyObject(await readBody(req), 'article');
  if (m === null) return unprocessable(res, 'invalid body');
  const title = reqString(m, 'title');
  const description = reqString(m, 'description');
  const body = reqString(m, 'body');
  if (title === null || description === null || body === null) {
    return unprocessable(res, 'title, description and body are required');
  }
  let tagList = [];
  if (hasOwn.call(m, 'tagList') && m.tagList !== null) {
    if (!Array.isArray(m.tagList)) return unprocessable(res, 'tagList must be an array of non-empty strings');
    for (const t of m.tagList) {
      if (typeof t !== 'string' || t === '') return unprocessable(res, 'tagList must be an array of non-empty strings');
    }
    tagList = m.tagList;
  }
  const v = String(viewer);
  const lit = pgArray(tagList);
  const spec = [];
  if (tagList.length > 0) spec.push(S.tagsIns, 1, lit);
  spec.push(S.articleIns, 5, v, title, description, body, lit);
  spec.push(S.articleByCurrId, 1, v);
  const r = await pg.exec(WRITE, spec);
  if (r.status === OK) return sendBuf(res, 201, r.buf);
  return dbFailure(res, r);
}

async function updateArticle(req, res, slug) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const m = bodyObject(await readBody(req), 'article');
  if (m === null) return unprocessable(res, 'invalid body');
  const title = optString(m, 'title', true);
  const description = optString(m, 'description', true);
  const body = optString(m, 'body', true);
  if (title === BAD || description === BAD || body === BAD) {
    return unprocessable(res, 'title, description and body must be non-empty strings');
  }
  const v = String(viewer);
  const r1 = await pg.exec(WRITE, [S.articleUpd, 5, v, slug, title ?? null, description ?? null, body ?? null]);
  if (r1.status !== OK) return dbFailure(res, r1);
  const code = r1.buf.toString('utf8');
  if (code === '404') return sendError(res, 404, 'article not found');
  if (code === '403') return sendError(res, 403, 'not the author');
  const r2 = await pg.exec(READ, [S.articleById, 2, v, code]);
  if (r2.status === OK) return sendBuf(res, 200, r2.buf);
  if (r2.status === NONE) return notFound(res);
  return dbFailure(res, r2);
}

async function deleteArticle(req, res, slug) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const r = await pg.exec(WRITE, [S.articleDel, 2, String(viewer), slug]);
  if (r.status !== OK) return dbFailure(res, r);
  const code = r.buf.toString('utf8');
  if (code === '204') return sendNoContent(res);
  if (code === '404') return sendError(res, 404, 'article not found');
  return sendError(res, 403, 'not the author');
}

// ------------------------------------------------------------------ favorites

async function favorite(req, res, slug, on) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const v = String(viewer);
  const r = await pg.exec(WRITE, [on ? S.favIns : S.favDel, 2, v, slug, S.articleBySlug, 2, v, slug]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  if (r.status === NONE) return notFound(res);
  return dbFailure(res, r);
}

// ------------------------------------------------------------------ comments

async function listComments(req, res, slug) {
  const viewer = optionalAuth(req, res);
  if (viewer < 0) return;
  const r = await pg.exec(READ, [S.commentsList, 2, String(viewer), slug]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  if (r.status === NONE) return notFound(res);
  return dbFailure(res, r);
}

async function createComment(req, res, slug) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  const m = bodyObject(await readBody(req), 'comment');
  if (m === null) return unprocessable(res, 'invalid body');
  const body = reqString(m, 'body');
  if (body === null) return unprocessable(res, 'body is required');
  const r = await pg.exec(WRITE, [S.commentIns, 3, String(viewer), slug, body]);
  if (r.status === OK) return sendBuf(res, 201, r.buf);
  if (r.status === NONE) return notFound(res);
  return dbFailure(res, r);
}

async function deleteComment(req, res, slug, rawId) {
  const viewer = requireAuth(req, res);
  if (viewer === 0) return;
  if (!isUint(rawId)) return sendError(res, 404, 'comment not found');
  const r = await pg.exec(WRITE, [S.commentDel, 3, String(viewer), rawId, slug]);
  if (r.status !== OK) return dbFailure(res, r);
  const code = r.buf.toString('utf8');
  if (code === '204') return sendNoContent(res);
  if (code === '404') return sendError(res, 404, 'comment not found');
  return sendError(res, 403, 'not the author');
}

// ------------------------------------------------------------------ tags

async function tags(res) {
  const r = await pg.exec(READ, [S.tags, 0]);
  if (r.status === OK) return sendBuf(res, 200, r.buf);
  return dbFailure(res, r);
}

// ------------------------------------------------------------------ router

async function handle(req, res) {
  const url = req.url;
  const qi = url.indexOf('?');
  const path = qi === -1 ? url : url.slice(0, qi);
  const qs = qi === -1 ? '' : url.slice(qi + 1);
  const segs = path.split('/');
  const m = req.method;
  if (segs.length < 3 || segs[0] !== '' || segs[1] !== 'api') return notFound(res);
  const a = segs[2];

  switch (segs.length) {
    case 3:
      switch (a) {
        case 'tags': if (m === 'GET') return tags(res); break;
        case 'users': if (m === 'POST') return register(req, res); break;
        case 'user':
          if (m === 'GET') return currentUser(req, res);
          if (m === 'PUT') return updateUser(req, res);
          break;
        case 'articles':
          if (m === 'GET') return listArticles(req, res, qs);
          if (m === 'POST') return createArticle(req, res);
          break;
        default: break;
      }
      break;

    case 4: {
      const b = segs[3];
      if (a === 'users') {
        if (b === 'login' && m === 'POST') return login(req, res);
      } else if (a === 'profiles') {
        if (m === 'GET') {
          const u = seg(b);
          if (u !== null) return getProfile(req, res, u);
        }
      } else if (a === 'articles') {
        if (b === 'feed' && m === 'GET') return feed(req, res, qs);
        const slug = seg(b);
        if (slug !== null) {
          if (m === 'GET') return getArticle(req, res, slug);
          if (m === 'PUT') return updateArticle(req, res, slug);
          if (m === 'DELETE') return deleteArticle(req, res, slug);
        }
      }
      break;
    }

    case 5: {
      const b = seg(segs[3]);
      const c = segs[4];
      if (b === null) break;
      if (a === 'profiles' && c === 'follow') {
        if (m === 'POST') return follow(req, res, b, true);
        if (m === 'DELETE') return follow(req, res, b, false);
      } else if (a === 'articles') {
        if (c === 'favorite') {
          if (m === 'POST') return favorite(req, res, b, true);
          if (m === 'DELETE') return favorite(req, res, b, false);
        } else if (c === 'comments') {
          if (m === 'GET') return listComments(req, res, b);
          if (m === 'POST') return createComment(req, res, b);
        }
      }
      break;
    }

    case 6: {
      const b = seg(segs[3]);
      if (a === 'articles' && segs[4] === 'comments' && m === 'DELETE' && b !== null) {
        return deleteComment(req, res, b, segs[5]);
      }
      break;
    }

    default: break;
  }
  return notFound(res);
}

module.exports = { handle };
