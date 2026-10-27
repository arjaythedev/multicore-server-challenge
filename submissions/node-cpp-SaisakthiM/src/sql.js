'use strict';
// Every statement returns at most ONE row with ONE column: the JSON response body (or a small status text),
// built by Postgres. The addon hands those bytes straight back; JS never touches row objects.
// Parameters are always sent as text and cast in SQL ($n::bigint, $n::text, ...), so inference never guesses.
// Timestamps: UTC, exactly 3 fractional digits, truncated (to_char MS truncates).

const STATEMENTS = [];
const S = {};
function def(name, sql) {
  if (S[name] !== undefined) throw new Error('duplicate statement ' + name);
  S[name] = STATEMENTS.length;
  STATEMENTS.push(sql);
}

const ts = (col) => `to_char(${col} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')`;
const slugify = (p) => `trim(both '-' from lower(regexp_replace(${p}, '[^A-Za-z0-9]+', '-', 'g')))`;
const followsExists = (follower, followee) =>
  `EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ${follower} AND fo.followee_id = ${followee})`;
const profileObj = (u, following) =>
  `json_build_object('username', ${u}.username, 'bio', ${u}.bio, 'image', ${u}.image, 'following', ${following})`;

// Needs aliases a (articles) and u (users) in scope; $1 = viewer.
function articleObj(withBody) {
  return `json_build_object(
    'slug', a.slug, 'title', a.title, 'description', a.description, ${withBody ? "'body', a.body," : ''}
    'tagList', ARRAY(SELECT t.name FROM article_tags atg JOIN tags t ON t.id = atg.tag_id WHERE atg.article_id = a.id ORDER BY t.name),
    'createdAt', ${ts('a.created_at')}, 'updatedAt', ${ts('a.updated_at')},
    'favorited', EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1::bigint),
    'favoritesCount', (SELECT count(*) FROM favorites f2 WHERE f2.article_id = a.id),
    'author', ${profileObj('u', followsExists('$1::bigint', 'a.author_id'))})`;
}

// ---------------------------------------------------------------- users
def('register', `WITH u AS (INSERT INTO users (username, email, password_hash) VALUES ($1::text, $2::text, $3::text)
  RETURNING id, username, email, bio, image)
  SELECT json_build_object('id', u.id, 'username', u.username, 'email', u.email, 'bio', u.bio, 'image', u.image) FROM u`);

def('login', `SELECT json_build_object('id', id, 'username', username, 'email', email, 'bio', bio, 'image', image,
  'hash', password_hash) FROM users WHERE email = $1::text`);

// $1 viewer, $2 token
def('userGet', `SELECT json_build_object('user', json_build_object('email', u.email, 'token', $2::text,
  'username', u.username, 'bio', u.bio, 'image', u.image)) FROM users u WHERE u.id = $1::bigint`);

// $1 viewer, $2 email, $3 username, $4 password_hash, $5 bio, $6 image, $7 token
def('userUpdate', `WITH u AS (UPDATE users SET email = COALESCE($2::text, email), username = COALESCE($3::text, username),
    password_hash = COALESCE($4::text, password_hash), bio = COALESCE($5::text, bio), image = COALESCE($6::text, image)
  WHERE id = $1::bigint RETURNING email, username, bio, image)
  SELECT json_build_object('user', json_build_object('email', u.email, 'token', $7::text, 'username', u.username,
    'bio', u.bio, 'image', u.image)) FROM u`);

// ---------------------------------------------------------------- profiles ($1 viewer, $2 username)
def('profile', `SELECT json_build_object('profile', ${profileObj('u', followsExists('$1::bigint', 'u.id'))})
  FROM users u WHERE u.username = $2::text`);

def('followIns', `INSERT INTO follows (follower_id, followee_id) SELECT $1::bigint, u.id FROM users u
  WHERE u.username = $2::text ON CONFLICT DO NOTHING`);

def('followDel', `DELETE FROM follows WHERE follower_id = $1::bigint
  AND followee_id = (SELECT u.id FROM users u WHERE u.username = $2::text)`);

// ---------------------------------------------------------------- article lists
// $1 viewer, $2 limit, $3 offset, ($4 filter). The page of ids is picked first (index walk), then only
// those rows are expanded. articlesCount is the reference's capped count (LIMIT 1000).
function listStatement(ids, count) {
  return `SELECT json_build_object(
    'articles', COALESCE(json_agg(${articleObj(false)} ORDER BY a.id DESC), '[]'::json),
    'articlesCount', (${count}))
  FROM (${ids}) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id`;
}
const PAGE = 'LIMIT $2::bigint OFFSET $3::bigint';

def('listAll', listStatement(
  `SELECT x.id FROM articles x ORDER BY x.id DESC ${PAGE}`,
  `SELECT count(*) FROM (SELECT 1 FROM articles c LIMIT 1000) s`));

def('listTag', listStatement(
  `SELECT x.article_id AS id FROM article_tags x
    WHERE x.tag_id = (SELECT t0.id FROM tags t0 WHERE t0.name = $4::text) ORDER BY x.article_id DESC ${PAGE}`,
  `SELECT count(*) FROM (SELECT 1 FROM article_tags c
    WHERE c.tag_id = (SELECT t1.id FROM tags t1 WHERE t1.name = $4::text) LIMIT 1000) s`));

def('listAuthor', listStatement(
  `SELECT x.id FROM articles x
    WHERE x.author_id = (SELECT au.id FROM users au WHERE au.username = $4::text) ORDER BY x.id DESC ${PAGE}`,
  `SELECT count(*) FROM (SELECT 1 FROM articles c
    WHERE c.author_id = (SELECT u1.id FROM users u1 WHERE u1.username = $4::text) LIMIT 1000) s`));

def('listFavorited', listStatement(
  `SELECT x.article_id AS id FROM favorites x
    WHERE x.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4::text) ORDER BY x.article_id DESC ${PAGE}`,
  `SELECT count(*) FROM (SELECT 1 FROM favorites c
    WHERE c.user_id = (SELECT fu1.id FROM users fu1 WHERE fu1.username = $4::text) LIMIT 1000) s`));

def('feed', listStatement(
  `SELECT x.id FROM follows fo0 CROSS JOIN LATERAL
      (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo0.followee_id ORDER BY a2.id DESC
        LIMIT ($2::bigint + $3::bigint)) x
    WHERE fo0.follower_id = $1::bigint ORDER BY x.id DESC ${PAGE}`,
  `SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id IN
      (SELECT fo1.followee_id FROM follows fo1 WHERE fo1.follower_id = $1::bigint) LIMIT 1000) s`));

// ---------------------------------------------------------------- single article
const articleFull = (where) => `SELECT json_build_object('article', ${articleObj(true)})
  FROM articles a JOIN users u ON u.id = a.author_id WHERE ${where}`;
def('articleBySlug', articleFull('a.slug = $2::text'));            // $1 viewer, $2 slug
def('articleById', articleFull('a.id = $2::bigint'));              // $1 viewer, $2 id
def('articleByCurrId', articleFull(`a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))`)); // $1 viewer

// POST /api/articles is three statements in ONE request (one implicit transaction, committed at the Sync):
// tagsIns (only with tags), articleIns, articleByCurrId. Requests never interleave on a connection, so the
// currval() in the last one is this request's own nextval().
def('tagsIns', `INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING`);

// $1 viewer, $2 title, $3 description, $4 body, $5 tag names as a text[] literal ('{}' when none)
def('articleIns', `WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
  a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, ${slugify('$2::text')} || '-' || n.id, $1::bigint, $2::text, $3::text, $4::text FROM n
        RETURNING id),
  l AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, t.id FROM a CROSS JOIN tags t
        WHERE t.name = ANY($5::text[]) RETURNING article_id)
  SELECT a.id::text FROM a`);

// $1 viewer, $2 slug, $3 title, $4 description, $5 body (null = unchanged). Returns '404', '403' or the id.
def('articleUpd', `WITH tgt AS (SELECT id, author_id FROM articles WHERE slug = $2::text),
  upd AS (UPDATE articles SET title = COALESCE($3::text, title), description = COALESCE($4::text, description),
            body = COALESCE($5::text, body),
            slug = CASE WHEN $3::text IS NULL THEN slug ELSE ${slugify('$3::text')} || '-' || id END,
            updated_at = now()
          WHERE id IN (SELECT id FROM tgt WHERE author_id = $1::bigint) RETURNING id)
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM tgt) THEN '404'
              WHEN EXISTS (SELECT 1 FROM upd) THEN (SELECT id::text FROM upd) ELSE '403' END`);

// $1 viewer, $2 slug. Returns '404', '403' or '204'.
def('articleDel', `WITH tgt AS (SELECT id, author_id FROM articles WHERE slug = $2::text),
  del AS (DELETE FROM articles WHERE id IN (SELECT id FROM tgt WHERE author_id = $1::bigint) RETURNING id)
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM tgt) THEN '404'
              WHEN EXISTS (SELECT 1 FROM del) THEN '204' ELSE '403' END`);

// ---------------------------------------------------------------- favorites ($1 viewer, $2 slug)
def('favIns', `INSERT INTO favorites (user_id, article_id) SELECT $1::bigint, a.id FROM articles a
  WHERE a.slug = $2::text ON CONFLICT DO NOTHING`);
def('favDel', `DELETE FROM favorites WHERE user_id = $1::bigint
  AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2::text)`);

// ---------------------------------------------------------------- comments
// $1 viewer, $2 slug. No row = unknown article (404).
def('commentsList', `SELECT json_build_object('comments', COALESCE((
    SELECT json_agg(json_build_object('id', c.id, 'createdAt', ${ts('c.created_at')}, 'updatedAt', ${ts('c.updated_at')},
        'body', c.body, 'author', ${profileObj('cu', followsExists('$1::bigint', 'c.author_id'))})
      ORDER BY c.created_at DESC, c.id DESC)
    FROM (SELECT c0.id, c0.body, c0.created_at, c0.updated_at, c0.author_id FROM comments c0
           WHERE c0.article_id = a.id ORDER BY c0.created_at DESC, c0.id DESC LIMIT 100) c
    JOIN users cu ON cu.id = c.author_id), '[]'::json))
  FROM articles a WHERE a.slug = $2::text`);

// $1 viewer, $2 slug, $3 body. No row = unknown article (404).
def('commentIns', `WITH c AS (INSERT INTO comments (article_id, author_id, body)
    SELECT a.id, $1::bigint, $3::text FROM articles a WHERE a.slug = $2::text
    RETURNING id, body, created_at, updated_at, author_id)
  SELECT json_build_object('comment', json_build_object('id', c.id, 'createdAt', ${ts('c.created_at')},
    'updatedAt', ${ts('c.updated_at')}, 'body', c.body, 'author', ${profileObj('u', 'false')}))
  FROM c JOIN users u ON u.id = c.author_id`);

// $1 viewer, $2 comment id, $3 slug. Returns '404', '403' or '204'.
def('commentDel', `WITH tgt AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
    WHERE c.id = $2::bigint AND a.slug = $3::text),
  del AS (DELETE FROM comments WHERE id IN (SELECT id FROM tgt WHERE author_id = $1::bigint) RETURNING id)
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM tgt) THEN '404'
              WHEN EXISTS (SELECT 1 FROM del) THEN '204' ELSE '403' END`);

// ---------------------------------------------------------------- tags
def('tags', `SELECT json_build_object('tags', COALESCE(json_agg(name ORDER BY name), '[]'::json)) FROM tags`);

module.exports = { STATEMENTS, S };
