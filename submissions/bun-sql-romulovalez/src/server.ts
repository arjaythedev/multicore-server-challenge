// Conduit on Bun.serve + Bun.SQL. The first process (the supervisor) spawns WORKERS copies of itself; each worker
// runs Bun.serve on the same port (reusePort: the kernel spreads connections) with its own two Postgres connections
// (db.ts). The supervisor runs bcrypt for every worker (bcrypt.ts), so interleaved sets fill up.
import { CryptoHasher, SQL, serve, spawn, type BunRequest, type Serve } from 'bun';
import * as db from './db.ts';
import { bcryptService, hash, verify as checkPassword } from './bcrypt.ts';

// ---- JWT, HS256: signature, `alg` and `exp` checked on every request (no remembered verifications: rule 5)

const SECRET = process.env.JWT_SECRET!;
const b64 = (s: string) => Buffer.from(s).toString('base64url');
const HEAD = b64('{"alg":"HS256","typ":"JWT"}');
function hmac(data: string) {
  const digest: unknown = new CryptoHasher('sha256', SECRET).update(data).digest('base64url');
  return typeof digest === 'string' ? digest : '';
}

function sign(id: number) {
  const now = Math.floor(Date.now() / 1000);
  const data = `${HEAD}.${b64(JSON.stringify({ sub: `${id}`, iat: now, exp: now + 30 * 86400 }))}`;
  return `${data}.${hmac(data)}`;
}

// user id from a valid token, else 0
function verify(token: string) {
  const [head, payload, sig, extra] = token.split('.');
  if (extra !== undefined || sig === undefined || hmac(`${head}.${payload}`) !== sig) return 0;
  try {
    if (head !== HEAD && JSON.parse(Buffer.from(head, 'base64url').toString()).alg !== 'HS256') return 0;
    const { sub, exp }: { sub?: unknown; exp?: unknown } = JSON.parse(Buffer.from(payload, 'base64url').toString());
    const id = typeof sub === 'string' && /^\d{1,15}$/.test(sub) ? Number(sub) : 0;
    return typeof exp === 'number' && exp > Date.now() / 1000 && id > 0 ? id : 0;
  } catch {
    return 0;
  }
}

// ---- request and response helpers

const json = (data: unknown, status = 200) => Response.json(data, { status });
const fail = (status: number, msg: string) => json({ errors: { body: [msg] } }, status);
const noContent = () => new Response(null, { status: 204 });

// thrown by handlers, turned into its response by the route table
class HttpError extends Error {
  constructor(readonly status: number, msg: string) { super(msg); }
}
function check(ok: unknown, status = 422, msg = 'invalid request'): asserts ok { if (!ok) throw new HttpError(status, msg); }

// viewer id: > 0 signed in, 0 anonymous; a header that isn't a valid token is a 401
function viewer(req: Request, required = false) {
  const h = req.headers.get('authorization');
  const id = h ? (h.startsWith('Token ') ? verify(h.slice(6)) : 0) : 0;
  check(h ? id > 0 : !required, 401, 'unauthorized');
  return id;
}
const token = (req: Request) => req.headers.get('authorization')!.slice(6);

// the JSON body's object under `key`
async function body(req: Request, key: string) {
  const b: Record<string, unknown> | null = await req.json().catch(() => null);
  const v = b?.[key];
  check(v !== null && typeof v === 'object' && !Array.isArray(v));
  return v as Record<string, unknown>;
}
const isText = (x: unknown): x is string => typeof x === 'string' && x !== '';
const isOptText = (x: unknown): x is string | null | undefined => x == null || isText(x);
const isPassword = (p: unknown): p is string => isText(p) && Buffer.byteLength(p) <= 72 && !p.includes('\0'); // bcrypt reads 72 bytes

// a unique violation
const unique = (e: unknown) => e instanceof SQL.PostgresError && e.errno === '23505';

// ?limit and ?offset of a list
function page(req: Request) {
  const q = new URL(req.url).searchParams;
  const int = (k: string, d: number) => (q.has(k) ? (/^\d{1,9}$/.test(q.get(k)!) ? Number(q.get(k)) : -1) : d);
  const limit = int('limit', 20), offset = int('offset', 0);
  check(limit >= 1 && limit <= 100 && offset >= 0);
  return { q, limit, offset };
}

// ---- routes (SPEC.md); rows arrive shaped as the response (Date fields serialise as ISO strings)

type User = { email: string; username: string; bio: string | null; image: string | null };
const user = (r: User, token: string) => ({ user: { email: r.email, token, username: r.username, bio: r.bio, image: r.image } });

async function articleList<A>(rows: Promise<{ article: A }[]>, count: Promise<{ n: number }[]>) {
  const [list, [c]] = await Promise.all([rows, count]);
  return json({ articles: list.map((r) => r.article), articlesCount: c.n });
}

async function articleResponse(v: number, id: number, status = 200) {
  const [r] = await db.articleById(v, id);
  return r ? json({ article: r.article }, status) : fail(404, 'not found');
}

async function ownArticle(v: number, slug: string) {
  const [a] = await db.articleOwner(slug);
  check(a, 404, 'not found');
  check(a.authorId === v, 403, 'forbidden');
  return a.id;
}

async function follow(req: BunRequest<'/api/profiles/:username/follow'>, on: boolean) {
  const v = viewer(req, true);
  const [p] = await db.profile(v, req.params.username);
  if (!p) return fail(404, 'not found');
  await (on ? db.addFollow : db.removeFollow)(v, p.id);
  return json({ profile: { username: p.username, bio: p.bio, image: p.image, following: on } });
}

async function favorite(req: BunRequest<'/api/articles/:slug/favorite'>, on: boolean) {
  const v = viewer(req, true);
  const [a] = await db.articleId(req.params.slug);
  if (!a) return fail(404, 'not found');
  await (on ? db.addFavorite : db.removeFavorite)(v, a.id);
  return articleResponse(v, a.id);
}

// a route table: each handler's request is typed by its path (req.params)
type Handler<P extends string> = (req: BunRequest<P>) => Response | Promise<Response>;
type Table<R extends string> = { [P in R]: { [M in Serve.HTTPMethod]?: Handler<P> } };
const table = <R extends string>(r: Table<R>) => r;

const routes = table({
  '/api/tags': {
    GET: async () => new Response((await db.tagList())[0].body, { headers: { 'Content-Type': 'application/json' } }),
  },
  '/api/users': {
    async POST(req) {
      const u = await body(req, 'user');
      check(isText(u.username) && isText(u.email) && isPassword(u.password));
      try {
        const [row] = await db.insertUser(u.username, u.email, await hash(u.password));
        return json(user(row, sign(row.id)), 201);
      } catch (e) {
        if (unique(e)) return fail(422, 'username or email already taken');
        throw e;
      }
    },
  },
  '/api/users/login': {
    async POST(req) {
      const u = await body(req, 'user');
      check(isText(u.email) && isText(u.password));
      const [row] = isPassword(u.password) ? await db.userByEmail(u.email) : [];
      const ok = row && (await checkPassword(u.password, row.passwordHash));
      return ok ? json(user(row, sign(row.id))) : fail(401, 'invalid email or password');
    },
  },
  '/api/user': {
    async GET(req) {
      const [row] = await db.userById(viewer(req, true));
      return row ? json(user(row, token(req))) : fail(401, 'unauthorized');
    },
    async PUT(req) {
      const v = viewer(req, true);
      const { email, username, password, bio, image } = await body(req, 'user');
      check(isOptText(email) && isOptText(username) && (password == null || isPassword(password)));
      check((bio == null || typeof bio === 'string') && (image == null || typeof image === 'string'));
      try {
        const hashed = password == null ? null : await hash(password);
        const [row] = await db.updateUser({ id: v, email: email ?? null, username: username ?? null, hash: hashed, bio: bio ?? null, image: image ?? null });
        return row ? json(user(row, token(req))) : fail(401, 'unauthorized');
      } catch (e) {
        if (unique(e)) return fail(422, 'username or email already taken');
        throw e;
      }
    },
  },
  '/api/profiles/:username': {
    async GET(req) {
      const [p] = await db.profile(viewer(req), req.params.username);
      return p ? json({ profile: { username: p.username, bio: p.bio, image: p.image, following: p.following } }) : fail(404, 'not found');
    },
  },
  '/api/profiles/:username/follow': {
    POST: (req) => follow(req, true),
    DELETE: (req) => follow(req, false),
  },
  '/api/articles': {
    GET(req) {
      const v = viewer(req);
      const { q, limit, offset } = page(req);
      const [tag, author, favorited] = [q.get('tag'), q.get('author'), q.get('favorited')];
      if (tag) return articleList(db.listTag(v, limit, offset, tag), db.countTag(tag));
      if (author) return articleList(db.listAuthor(v, limit, offset, author), db.countAuthor(author));
      if (favorited) return articleList(db.listFavorited(v, limit, offset, favorited), db.countFavorited(favorited));
      return articleList(db.listAll(v, limit, offset), db.countAll());
    },
    async POST(req) {
      const v = viewer(req, true);
      const a = await body(req, 'article');
      const tags = a.tagList ?? [];
      check(isText(a.title) && isText(a.description) && isText(a.body) && Array.isArray(tags) && tags.every(isText));
      const names = [...new Set(tags)].sort(); // one lock order for concurrent tag inserts
      const [row] = await db.insertArticle({ author: v, title: a.title, description: a.description, body: a.body, tags: names });
      return articleResponse(v, row.id, 201);
    },
  },
  '/api/articles/feed': {
    GET(req) {
      const v = viewer(req, true);
      const { limit, offset } = page(req);
      return articleList(db.listFeed(v, limit, offset), db.countFeed(v));
    },
  },
  '/api/articles/:slug': {
    async GET(req) {
      const [a] = await db.articleBySlug(viewer(req), req.params.slug);
      return a ? json({ article: a.article }) : fail(404, 'not found');
    },
    async PUT(req) {
      const v = viewer(req, true);
      const { title, description, body: text } = await body(req, 'article');
      check(isOptText(title) && isOptText(description) && isOptText(text));
      const id = await ownArticle(v, req.params.slug);
      await db.updateArticle({ id, title: title ?? null, description: description ?? null, body: text ?? null });
      return articleResponse(v, id);
    },
    async DELETE(req) {
      const v = viewer(req, true);
      await db.deleteArticle(await ownArticle(v, req.params.slug));
      return noContent();
    },
  },
  '/api/articles/:slug/favorite': {
    POST: (req) => favorite(req, true),
    DELETE: (req) => favorite(req, false),
  },
  '/api/articles/:slug/comments': {
    async GET(req) {
      const v = viewer(req);
      const [rows, [a]] = await Promise.all([db.commentsOf(v, req.params.slug), db.articleId(req.params.slug)]);
      return a ? json({ comments: rows.map((r) => r.comment) }) : fail(404, 'not found');
    },
    async POST(req) {
      const v = viewer(req, true);
      const c = await body(req, 'comment');
      check(isText(c.body));
      const [a] = await db.articleId(req.params.slug);
      if (!a) return fail(404, 'not found');
      // the author is the viewer: read alongside the insert
      const [[row], [me]] = await Promise.all([db.addComment(a.id, v, c.body), db.userById(v)]);
      return json({ comment: { ...row, author: { username: me.username, bio: me.bio, image: me.image, following: false } } }, 201);
    },
  },
  '/api/articles/:slug/comments/:id': {
    async DELETE(req) {
      const v = viewer(req, true);
      const id = /^\d{1,15}$/.test(req.params.id) ? Number(req.params.id) : 0;
      const [c] = id ? await db.commentOwner(id, req.params.slug) : [];
      check(c, 404, 'not found');
      check(c.authorId === v, 403, 'forbidden');
      await db.deleteComment(id);
      return noContent();
    },
  },
});

// ---- start

const env = process.env;

if (!env.WORKER) {
  // half the cores: Postgres needs the rest, and fewer workers make bigger batches
  const n = Number(env.WORKERS) || Math.max(1, Math.round(navigator.hardwareConcurrency / 2));
  const bcrypt = bcryptService({ threads: Number(env.BCRYPT_THREADS) || 2, waitMs: Number(env.BCRYPT_WAIT_MS) || 100 });
  const workers = Array.from({ length: n }, (_, i) =>
    // compiled (bun compile), the executable is the program: no script argument
    spawn(import.meta.path.startsWith('/$bunfs/') ? [process.execPath] : [process.execPath, import.meta.path], {
      env: { ...env, WORKER: `${i + 1}` },
      stdio: ['ignore', 'inherit', 'inherit'],
      ipc: (m: { id: number; pw: string; setting: string }, child) => bcrypt(m.pw, m.setting, (h) => child.send({ id: m.id, hash: h })),
    }));
  // a crashed worker is not restarted: stop everything
  for (const w of workers) w.exited.then((code) => { console.error(`worker exited (${code})`); for (const x of workers) x.kill(); process.exit(1); });
  console.log(`Bun ${Bun.version}: ${n} workers, each with 1 read + 1 write Postgres connection`);
} else {
  serve({
    hostname: env.HOST || '0.0.0.0',
    port: Number(env.PORT) || 80,
    reusePort: true,
    idleTimeout: 120,
    development: false,
    routes,
    fetch: () => fail(404, 'not found'),
    // a handler's HttpError becomes its response
    error: (e) => {
      if (e instanceof HttpError) return fail(e.status, e.message);
      console.error(e);
      return fail(500, 'internal error');
    },
  });
}
