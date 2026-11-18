// Every statement the server runs, as Bun.SQL tagged templates: with `prepare: true` each one is a named prepared
// statement on its connection, so a request only sends its values. Reads are batched: calls within one BATCH_MS
// window share one execution. Rows come back with the response's field names (SQL aliases); the article and comment
// rows are nested by a small typed mapper (Bun.SQL rows are flat).
import { SQL } from 'bun';

const client = () => new SQL({
  url: process.env.DATABASE_URL,
  max: 1,
  idleTimeout: 0, // idle connections stay open: their prepared statements go with them
  maxLifetime: 0,
  prepare: true,
  // session settings: no JIT or parallel workers for millisecond queries, and one generic plan per statement
  connection: { jit: 'off', plan_cache_mode: 'force_generic_plan', max_parallel_workers_per_gather: '0' },
});
// One connection for reads (Bun.SQL pipelines concurrent queries on it) and one for writes, so reads never queue
// behind a commit's WAL flush. Ids are bigint columns; statements return them as float8 (exact to 2^53), decoded to
// numbers in binary.
const read = client();
const write = client();

// ---- batching (the DataLoader pattern)

// batch(run) returns load(...args). Identical calls in a window are one call; argument c of every call in the
// window makes column c, and run(...columns) is the statement over those arrays (`(vs: number[], slugs: string[]) =>`
// gives load(v: number, slug: string)). Rows come back tagged with `i`, the 1-based position of their call. Nothing
// outlives its batch. 40 ms: 7% less CPU per request than 20 ms on 8 cores (p99 +35 ms; measured).
const BATCH_MS = Number(process.env.BATCH_MS) || 40;

// one call waiting for its batch (or its group commit)
class Call<Args, Row> {
  resolve: (rows: Row[]) => void = () => {};
  reject: (e: unknown) => void = () => {};
  readonly promise = new Promise<Row[]>((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
  constructor(readonly args: Args) {}
}

type Args<Columns extends unknown[][]> = { [C in keyof Columns]: Columns[C][number] };
function batch<Row extends { i: number }, Columns extends unknown[][]>(run: (...columns: Columns) => Promise<Row[]>) {
  type A = Args<Columns> & unknown[];
  let calls: Map<string, Call<A, Row>> | null = null;
  async function flush(list: Call<A, Row>[]) {
    const columns: unknown[][] = [];
    for (let c = 0; c < list[0].args.length; c++) {
      const column: unknown[] = [];
      for (const k of list) column.push(k.args[c]);
      columns.push(column);
    }
    try {
      const rows = await run(...(columns as Columns));
      const out: Row[][] = [];
      for (let j = 0; j < list.length; j++) out.push([]);
      for (const r of rows) out[r.i - 1].push(r);
      for (let j = 0; j < list.length; j++) list[j].resolve(out[j]);
    } catch (e) {
      for (const k of list) k.reject(e);
    }
  }
  return (...args: A) => {
    if (calls === null) {
      const window = (calls = new Map());
      setTimeout(() => { calls = null; flush([...window.values()]); }, BATCH_MS);
    }
    const id = args.join('\0');
    let k = calls.get(id);
    if (k === undefined) calls.set(id, (k = new Call(args)));
    return k.promise;
  };
}

// ---- articles

export type Author = { username: string; bio: string | null; image: string | null; following: boolean };
export type Article = {
  slug: string; title: string; description: string; body?: string; tagList: string[];
  createdAt: Date; updatedAt: Date; favorited: boolean; favoritesCount: number; author: Author;
};
type ArticleRow = Omit<Article, 'author'> & Omit<Author, 'following'> & { i: number; following: boolean };
const article = (r: ArticleRow): { i: number; article: Article } => ({
  i: r.i,
  article: {
    slug: r.slug, title: r.title, description: r.description, body: r.body, tagList: r.tagList,
    createdAt: r.createdAt, updatedAt: r.updatedAt, favorited: r.favorited, favoritesCount: r.favoritesCount,
    author: { username: r.username, bio: r.bio, image: r.image, following: r.following },
  },
});

// After the CTE k of a statement below (call i wants article id, seen by viewer v; 0: anonymous): author, favorite
// count and tags are read once per distinct article in the batch (CTE a; tag names in one join for the batch, CTE t),
// and the viewer's flags are one primary-key range scan per signed-in viewer (`= ANY` of that viewer's articles or
// authors in the batch; MATERIALIZED, or the generic plan reruns the scan per row: 300 µs per request). Lists don't
// send bodies. Constant text, spliced as written: the statement stays one prepared statement.
const enrich = (withBody: boolean) => `
  a AS MATERIALIZED (
    SELECT a.id, a.slug, a.title, a.description, ${withBody ? 'a.body,' : ''} a.created_at AS "createdAt", a.updated_at AS "updatedAt",
           a.author_id, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id)::int AS "favoritesCount", u.username, u.bio, u.image
      FROM articles a JOIN users u ON u.id = a.author_id
     WHERE a.id = ANY(ARRAY(SELECT DISTINCT id FROM k))),
  t AS (
    SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tag_list
      FROM article_tags at JOIN tags t ON t.id = at.tag_id
     WHERE at.article_id = ANY(ARRAY(SELECT id FROM a)) GROUP BY at.article_id),
  fav AS MATERIALIZED (
    SELECT p.v, f.article_id
      FROM (SELECT v, array_agg(DISTINCT id) AS ids FROM k WHERE v <> 0 GROUP BY v) p
     CROSS JOIN LATERAL (SELECT article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.ids)) f),
  fol AS MATERIALIZED (
    SELECT p.v, fo.followee_id
      FROM (SELECT k.v, array_agg(DISTINCT a.author_id) AS ids FROM k JOIN a ON a.id = k.id WHERE k.v <> 0 GROUP BY k.v) p
     CROSS JOIN LATERAL (SELECT followee_id FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id = ANY(p.ids)) fo)
  SELECT k.i::int AS i, a.slug, a.title, a.description, ${withBody ? 'a.body,' : ''} a."createdAt", a."updatedAt", a."favoritesCount",
         a.username, a.bio, a.image, COALESCE(t.tag_list, '{}') AS "tagList", fav.v IS NOT NULL AS favorited, fol.v IS NOT NULL AS following
    FROM k JOIN a ON a.id = k.id LEFT JOIN t ON t.article_id = a.id
    LEFT JOIN fav ON fav.v = k.v AND fav.article_id = k.id
    LEFT JOIN fol ON fol.v = k.v AND fol.followee_id = a.author_id
   ORDER BY k.i, a.id DESC`;
const withBody = read.unsafe(enrich(true)), withoutBody = read.unsafe(enrich(false));
const articles = (rows: ArticleRow[]) => rows.map(article);

// Each kind of read below is one statement for all its variants (by slug or id; the five lists; the five counts), so
// a window runs one execution per kind, not one per variant: the variant is an argument, and CASE runs only the
// subquery its branch picks. The read connection is one Postgres backend per worker; under load every execution's
// fixed cost queues the reads behind it (splitting them: 58% more executions per request; measured).

// a slug, or else (slug '') an article id
const single = batch((vs: number[], slugs: string[], ids: number[]) => read<ArticleRow[]>`
  WITH k AS MATERIALIZED (
    SELECT k.i, k.v, CASE k.slug WHEN '' THEN k.id ELSE (SELECT id FROM articles WHERE slug = k.slug) END AS id
      FROM unnest(${vs}::bigint[], ${slugs}::text[], ${ids}::bigint[]) WITH ORDINALITY k(v, slug, id, i)),
  ${withBody}`.then(articles));
export const articleBySlug = (v: number, slug: string) => single(v, slug, 0);
export const articleById = (v: number, id: number) => single(v, '', id);

// One page per call: the subquery of kind k.kind yields the page's article ids from k.v the viewer, k.lim, k.off and
// k.key (the tag or username). The ids come back as an ARRAY, so the planner joins per article by primary key (a
// LATERAL subquery with LIMIT k.lim is estimated at 10% of the table and gets a hash join over all of them).
type List = 'all' | 'tag' | 'author' | 'favorited' | 'feed';
const lists = batch((vs: number[], kinds: List[], lims: number[], offs: number[], keys: string[]) => read<ArticleRow[]>`
  WITH k AS MATERIALIZED (
    SELECT k.i, k.v, x.id
      FROM unnest(${vs}::bigint[], ${kinds}::text[], ${lims}::int[], ${offs}::int[], ${keys}::text[]) WITH ORDINALITY k(v, kind, lim, off, key, i)
     CROSS JOIN LATERAL unnest(CASE k.kind
       WHEN 'all' THEN ARRAY(SELECT id FROM articles ORDER BY id DESC LIMIT k.lim OFFSET k.off)
       WHEN 'tag' THEN ARRAY(SELECT article_id FROM article_tags WHERE tag_id = (SELECT id FROM tags WHERE name = k.key)
                              ORDER BY article_id DESC LIMIT k.lim OFFSET k.off)
       WHEN 'author' THEN ARRAY(SELECT id FROM articles WHERE author_id = (SELECT id FROM users WHERE username = k.key)
                                 ORDER BY id DESC LIMIT k.lim OFFSET k.off)
       WHEN 'favorited' THEN ARRAY(SELECT article_id FROM favorites WHERE user_id = (SELECT id FROM users WHERE username = k.key)
                                    ORDER BY article_id DESC LIMIT k.lim OFFSET k.off)
       WHEN 'feed' THEN ARRAY(SELECT x.id FROM follows fo CROSS JOIN LATERAL
                                (SELECT id FROM articles WHERE author_id = fo.followee_id ORDER BY id DESC LIMIT k.lim + k.off) x
                               WHERE fo.follower_id = k.v ORDER BY x.id DESC LIMIT k.lim OFFSET k.off)
     END) x(id)),
  ${withoutBody}`.then(articles));
export const listAll = (v: number, lim: number, off: number) => lists(v, 'all', lim, off, '');
export const listTag = (v: number, lim: number, off: number, tag: string) => lists(v, 'tag', lim, off, tag);
export const listAuthor = (v: number, lim: number, off: number, name: string) => lists(v, 'author', lim, off, name);
export const listFavorited = (v: number, lim: number, off: number, name: string) => lists(v, 'favorited', lim, off, name);
export const listFeed = (v: number, lim: number, off: number) => lists(v, 'feed', lim, off, '');

// counts are capped at 1,000 (SPEC.md); one count per distinct kind and key
const counts = batch((kinds: List[], keys: string[]) => read<{ i: number; n: number }[]>`
  SELECT k.i::int AS i, CASE k.kind
    WHEN 'all' THEN (SELECT count(*)::int FROM (SELECT 1 FROM articles LIMIT 1000) s)
    WHEN 'tag' THEN (SELECT count(*)::int FROM (SELECT 1 FROM article_tags WHERE tag_id = (SELECT id FROM tags WHERE name = k.key) LIMIT 1000) s)
    WHEN 'author' THEN (SELECT count(*)::int FROM (SELECT 1 FROM articles WHERE author_id = (SELECT id FROM users WHERE username = k.key) LIMIT 1000) s)
    WHEN 'favorited' THEN (SELECT count(*)::int FROM (SELECT 1 FROM favorites WHERE user_id = (SELECT id FROM users WHERE username = k.key) LIMIT 1000) s)
    WHEN 'feed' THEN (SELECT count(*)::int FROM (SELECT 1 FROM articles WHERE author_id IN
                       (SELECT followee_id FROM follows WHERE follower_id = k.key::bigint) LIMIT 1000) s)
  END AS n
    FROM unnest(${kinds}::text[], ${keys}::text[]) WITH ORDINALITY k(kind, key, i)`);
export const countAll = () => counts('all', '');
export const countTag = (tag: string) => counts('tag', tag);
export const countAuthor = (name: string) => counts('author', name);
export const countFavorited = (name: string) => counts('favorited', name);
export const countFeed = (v: number) => counts('feed', `${v}`);

export const articleOwner = (slug: string) => read<{ id: number; authorId: number }[]>`
  SELECT id::float8 AS id, author_id::float8 AS "authorId" FROM articles WHERE slug = ${slug}`;

// One atomic statement: the article, any new tags (sorted: one lock order) and the article's tags.
type NewArticle = { author: number; title: string; description: string; body: string; tags: string[] };
export const insertArticle = ({ author, title, description, body, tags }: NewArticle) => write<{ id: number }[]>`
  WITH a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
             SELECT n.id, trim(both '-' from lower(regexp_replace(${title}::text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
                    ${author}, ${title}, ${description}, ${body}
               FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
             RETURNING id),
  t AS (INSERT INTO tags (name) SELECT unnest(${tags}::text[]) ORDER BY 1 ON CONFLICT (name) DO NOTHING RETURNING id),
  x AS (INSERT INTO article_tags (article_id, tag_id)
        SELECT a.id, t.id FROM a, (SELECT id FROM t UNION SELECT id FROM tags WHERE name = ANY(${tags}::text[])) t)
  SELECT id::float8 AS id FROM a`;
// null keeps a field
type ArticleEdit = { id: number; title: string | null; description: string | null; body: string | null };
export const updateArticle = ({ id, title, description, body }: ArticleEdit) => write`
  UPDATE articles SET title = COALESCE(${title}::text, title), description = COALESCE(${description}::text, description),
         body = COALESCE(${body}::text, body), updated_at = now(),
         slug = CASE WHEN ${title}::text IS NULL THEN slug
                     ELSE trim(both '-' from lower(regexp_replace(${title}::text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END
   WHERE id = ${id}`;
export const deleteArticle = (id: number) => write`DELETE FROM articles WHERE id = ${id}`;

// ---- comments

export type Comment = { id: number; createdAt: Date; updatedAt: Date; body: string; author: Author };
type CommentRow = Omit<Comment, 'author'> & Author & { i: number };
const comment = (r: CommentRow): { i: number; comment: Comment } => ({
  i: r.i,
  comment: {
    id: r.id, createdAt: r.createdAt, updatedAt: r.updatedAt, body: r.body,
    author: { username: r.username, bio: r.bio, image: r.image, following: r.following },
  },
});

// Each distinct article's newest 100 comments are read once per batch (CTE c); the viewers' flags are one primary-key
// range scan per signed-in viewer (CTE fol, MATERIALIZED), as for articles.
export const commentsOf = batch((vs: number[], slugs: string[]) => read<CommentRow[]>`
  WITH k AS MATERIALIZED (SELECT * FROM unnest(${vs}::bigint[], ${slugs}::text[]) WITH ORDINALITY k(v, slug, i)),
  c AS MATERIALIZED (
    SELECT s.slug, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
      FROM (SELECT DISTINCT slug FROM k) s
     CROSS JOIN LATERAL (SELECT * FROM comments WHERE article_id = (SELECT id FROM articles WHERE slug = s.slug)
                          ORDER BY created_at DESC, id DESC LIMIT 100) c
      JOIN users u ON u.id = c.author_id),
  fol AS MATERIALIZED (
    SELECT p.v, fo.followee_id
      FROM (SELECT k.v, array_agg(DISTINCT c.author_id) AS ids FROM k JOIN c ON c.slug = k.slug WHERE k.v <> 0 GROUP BY k.v) p
     CROSS JOIN LATERAL (SELECT followee_id FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id = ANY(p.ids)) fo)
  SELECT k.i::int AS i, c.id::float8 AS id, c.created_at AS "createdAt", c.updated_at AS "updatedAt", c.body,
         c.username, c.bio, c.image, fol.v IS NOT NULL AS following
    FROM k JOIN c ON c.slug = k.slug LEFT JOIN fol ON fol.v = k.v AND fol.followee_id = c.author_id
   ORDER BY k.i, c.created_at DESC, c.id DESC`.then((rows) => rows.map(comment)));

export const articleId = batch((slugs: string[]) => read<{ i: number; id: number }[]>`
  SELECT k.i::int AS i, a.id::float8 AS id FROM unnest(${slugs}::text[]) WITH ORDINALITY k(slug, i) JOIN articles a ON a.slug = k.slug`);

export const commentOwner = (id: number, slug: string) => read<{ authorId: number }[]>`
  SELECT c.author_id::float8 AS "authorId" FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = ${id} AND a.slug = ${slug}`;
export const deleteComment = (id: number) => write`DELETE FROM comments WHERE id = ${id}`;

// ---- users and profiles

export type User = { id: number; email: string; username: string; bio: string | null; image: string | null };
export const insertUser = (username: string, email: string, hash: string) => write<User[]>`
  INSERT INTO users (username, email, password_hash) VALUES (${username}, ${email}, ${hash})
  RETURNING id::float8 AS id, email, username, bio, image`;
export const userByEmail = (email: string) => read<(User & { passwordHash: string })[]>`
  SELECT id::float8 AS id, email, username, bio, image, password_hash AS "passwordHash" FROM users WHERE email = ${email}`;
// null keeps a field
type UserEdit = { id: number; email: string | null; username: string | null; hash: string | null; bio: string | null; image: string | null };
export const updateUser = ({ id, email, username, hash, bio, image }: UserEdit) => write<User[]>`
  UPDATE users SET email = COALESCE(${email}::text, email), username = COALESCE(${username}::text, username),
         password_hash = COALESCE(${hash}::text, password_hash), bio = COALESCE(${bio}::text, bio), image = COALESCE(${image}::text, image)
   WHERE id = ${id} RETURNING id::float8 AS id, email, username, bio, image`;

export const userById = batch((ids: number[]) => read<(User & { i: number })[]>`
  SELECT k.i::int AS i, u.id::float8 AS id, u.email, u.username, u.bio, u.image
    FROM unnest(${ids}::bigint[]) WITH ORDINALITY k(id, i) JOIN users u ON u.id = k.id`);

// anonymous viewers (v = 0) skip the probe
export const profile = batch((vs: number[], names: string[]) => read<(Author & { i: number; id: number })[]>`
  SELECT k.i::int AS i, u.id::float8 AS id, u.username, u.bio, u.image,
         k.v <> 0 AND EXISTS (SELECT 1 FROM follows WHERE follower_id = k.v AND followee_id = u.id) AS following
    FROM unnest(${vs}::bigint[], ${names}::text[]) WITH ORDINALITY k(v, name, i) JOIN users u ON u.username = k.name`);

// GET /api/tags: the finished body, built by Postgres (200 one-column rows cost more to decode than to build); every
// caller in a window is the same call, `i` = 1.
export const tagList = batch(() => read<{ i: number; body: string }[]>`
  SELECT 1 AS i, json_build_object('tags', COALESCE(json_agg(name ORDER BY name), '[]'))::text AS body FROM tags`);

// ---- group commit

// Favorites, unfavorites, follows, unfollows and new comments waiting within WRITE_MS share one statement, one
// data-modifying WITH per kind over arrays of the calls' arguments: one transaction and one WAL flush, and each
// request is answered after the commit (rule 6). If Postgres rejects the group (it rolled back: an article deleted
// meanwhile), every write is retried alone, so one bad write fails only its own request; any other failure (a lost
// connection: the outcome is unknown) fails them all, without a retry. New comments take their ids in call order.
const WRITE_MS = Number(process.env.WRITE_MS) || 3;
export type NewComment = { id: number; createdAt: Date; updatedAt: Date; body: string };
const alone = {
  favorite: (v: number, id: number) => write<NewComment[]>`INSERT INTO favorites (user_id, article_id) VALUES (${v}, ${id}) ON CONFLICT DO NOTHING`,
  unfavorite: (v: number, id: number) => write<NewComment[]>`DELETE FROM favorites WHERE user_id = ${v} AND article_id = ${id}`,
  follow: (v: number, id: number) => write<NewComment[]>`INSERT INTO follows (follower_id, followee_id) VALUES (${v}, ${id}) ON CONFLICT DO NOTHING`,
  unfollow: (v: number, id: number) => write<NewComment[]>`DELETE FROM follows WHERE follower_id = ${v} AND followee_id = ${id}`,
  comment: (article: number, author: number, body: string) => write<NewComment[]>`
    INSERT INTO comments (article_id, author_id, body) VALUES (${article}, ${author}, ${body})
    RETURNING id::float8 AS id, created_at AS "createdAt", updated_at AS "updatedAt", body`,
};
type Kind = keyof typeof alone;
type Group = { [K in Kind]: Call<Parameters<(typeof alone)[K]>, NewComment>[] };

const column = <K extends Kind, C extends number>(g: Group, kind: K, c: C) => g[kind].map((k) => k.args[c]);
const writeGroup = (g: Group) => write<(NewComment & { i: number })[]>`
  WITH fav AS (INSERT INTO favorites (user_id, article_id)
               SELECT * FROM unnest(${column(g, 'favorite', 0)}::bigint[], ${column(g, 'favorite', 1)}::bigint[]) ON CONFLICT DO NOTHING),
  unfav AS (DELETE FROM favorites f USING unnest(${column(g, 'unfavorite', 0)}::bigint[], ${column(g, 'unfavorite', 1)}::bigint[]) k(v, id)
             WHERE f.user_id = k.v AND f.article_id = k.id),
  fol AS (INSERT INTO follows (follower_id, followee_id)
          SELECT * FROM unnest(${column(g, 'follow', 0)}::bigint[], ${column(g, 'follow', 1)}::bigint[]) ON CONFLICT DO NOTHING),
  unfol AS (DELETE FROM follows f USING unnest(${column(g, 'unfollow', 0)}::bigint[], ${column(g, 'unfollow', 1)}::bigint[]) k(v, id)
             WHERE f.follower_id = k.v AND f.followee_id = k.id),
  k AS MATERIALIZED (SELECT nextval(pg_get_serial_sequence('comments', 'id')) AS id, k.*
                       FROM (SELECT * FROM unnest(${column(g, 'comment', 0)}::bigint[], ${column(g, 'comment', 1)}::bigint[],
                                                  ${column(g, 'comment', 2)}::text[]) WITH ORDINALITY k(article, author, body, i) ORDER BY i) k),
  c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, article, author, body FROM k
        RETURNING id, created_at, updated_at, body)
  SELECT k.i::int AS i, c.id::float8 AS id, c.created_at AS "createdAt", c.updated_at AS "updatedAt", c.body FROM c JOIN k ON k.id = c.id`;

let pending: Group | null = null;
async function flushWrites(g: Group) {
  let rows;
  try {
    rows = await writeGroup(g);
  } catch (e) {
    const rolledBack = e instanceof SQL.PostgresError && e.errno !== undefined; // a SQLSTATE: Postgres rejected it
    for (const k of g.favorite) rolledBack ? alone.favorite(...k.args).then(k.resolve, k.reject) : k.reject(e);
    for (const k of g.unfavorite) rolledBack ? alone.unfavorite(...k.args).then(k.resolve, k.reject) : k.reject(e);
    for (const k of g.follow) rolledBack ? alone.follow(...k.args).then(k.resolve, k.reject) : k.reject(e);
    for (const k of g.unfollow) rolledBack ? alone.unfollow(...k.args).then(k.resolve, k.reject) : k.reject(e);
    for (const k of g.comment) rolledBack ? alone.comment(...k.args).then(k.resolve, k.reject) : k.reject(e);
    return;
  }
  for (const k of g.favorite) k.resolve([]);
  for (const k of g.unfavorite) k.resolve([]);
  for (const k of g.follow) k.resolve([]);
  for (const k of g.unfollow) k.resolve([]);
  for (const { i, id, createdAt, updatedAt, body } of rows) g.comment[i - 1].resolve([{ id, createdAt, updatedAt, body }]);
}
const grouped = <K extends Kind>(kind: K) => (...args: Parameters<(typeof alone)[K]>) => {
  if (pending === null) {
    const g = (pending = { favorite: [], unfavorite: [], follow: [], unfollow: [], comment: [] });
    setTimeout(() => { pending = null; flushWrites(g); }, WRITE_MS);
  }
  const k = new Call<typeof args, NewComment>(args);
  (pending[kind] as (typeof k)[]).push(k);
  return k.promise;
};
// each resolves once committed; addComment resolves to [new comment]
export const addFavorite = grouped('favorite');
export const removeFavorite = grouped('unfavorite');
export const addFollow = grouped('follow');
export const removeFollow = grouped('unfollow');
export const addComment = grouped('comment');
