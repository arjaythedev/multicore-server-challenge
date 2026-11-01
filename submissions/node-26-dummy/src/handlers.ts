import { authenticate, authenticateUser, fail, first, issueToken, optional, pagination, passwordHash,
  passwordMatches, pool, readBody, safeInteger, sendJson, string, transaction, validId,
  type Handler, type RequestContext, type UserRow } from './utils.js';

interface Profile { username: string; bio: string | null; image: string | null; following: boolean }
interface ArticleRow extends Profile {
  id: string; slug: string; title: string; description: string; body: string;
  created_at: Date; updated_at: Date; tag_list: string[]; favorites_count: string; favorited: boolean;
}
interface CommentRow extends Profile { id: string; body: string; created_at: Date; updated_at: Date }
interface ArticleResponse {
  slug: string; title: string; description: string; body?: string; tagList: string[];
  createdAt: string; updatedAt: string; favorited: boolean; favoritesCount: number; author: Profile;
}
const userColumns = 'id, username, email, bio, image';
const profile = (row: Profile): Profile => ({ username: row.username, bio: row.bio, image: row.image, following: row.following });
const user = (row: UserRow, token: string) => ({ email: row.email, username: row.username, bio: row.bio, image: row.image, token });
const article = (row: ArticleRow, full: boolean): ArticleResponse => ({
  slug: row.slug, title: row.title, description: row.description, ...(full ? { body: row.body } : {}),
  tagList: row.tag_list, createdAt: row.created_at.toISOString(), updatedAt: row.updated_at.toISOString(),
  favorited: row.favorited, favoritesCount: safeInteger(row.favorites_count), author: profile(row),
});
const comment = (row: CommentRow) => ({ id: safeInteger(row.id), body: row.body,
  createdAt: row.created_at.toISOString(), updatedAt: row.updated_at.toISOString(), author: profile(row) });

// $1 is always the viewer, including anonymous viewer 0.
const articleSelect = (full: boolean): string => `SELECT a.id,a.slug,a.title,a.description,${full ? 'a.body,' : ''}
  a.created_at,a.updated_at,
  ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id ORDER BY t.name) tag_list,
  (SELECT count(*) FROM favorites f WHERE f.article_id=a.id) favorites_count,
  EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=a.id AND f.user_id=$1) favorited,
  u.username,u.bio,u.image,
  EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=$1 AND f.followee_id=a.author_id) following
  FROM articles a JOIN users u ON u.id=a.author_id`;
const slugify = (expression: string): string => `trim(both '-' from lower(regexp_replace(${expression}, '[^A-Za-z0-9]+', '-', 'g')))`;
async function articleById(id: string, viewer: string): Promise<ArticleResponse> {
  const result = await pool.query<ArticleRow>(`${articleSelect(true)} WHERE a.id=$2`, [viewer, id]);
  return article(first(result.rows), true);
}
async function articleIdentity(slug: string | undefined): Promise<{ id: string; author_id: string }> {
  return first((await pool.query<{ id: string; author_id: string }>('SELECT id,author_id FROM articles WHERE slug=$1', [slug])).rows);
}
function owner(actual: string, viewer: string): void { if (actual !== viewer) fail(403, 'Not the author'); }

export const registerUser: Handler = async ({ request, response }) => {
  const b = await readBody(request, 'user');
  const username = string(b.username), email = string(b.email), password = string(b.password);
  const hash = await passwordHash(password);
  const row = first((await pool.query<UserRow>(`INSERT INTO users(username,email,password_hash) VALUES($1,$2,$3) RETURNING ${userColumns}`, [username, email, hash])).rows);
  sendJson(response, 201, { user: user(row, await issueToken(row.id)) });
};
export const loginUser: Handler = async ({ request, response }) => {
  const b = await readBody(request, 'user');
  const email = string(b.email), password = string(b.password);
  const row = first((await pool.query<UserRow & { password_hash: string }>(`SELECT ${userColumns},password_hash FROM users WHERE email=$1`, [email])).rows, 401);
  if (!await passwordMatches(password, row.password_hash)) fail(401, 'Invalid credentials');
  sendJson(response, 200, { user: user(row, await issueToken(row.id)) });
};
export const getCurrentUser: Handler = async ({ request, response }) => {
  const { row, token } = await authenticateUser(request);
  sendJson(response, 200, { user: user(row, token) });
};
export const updateCurrentUser: Handler = async ({ request, response }) => {
  const auth = await authenticate(request);
  const b = await readBody(request, 'user');
  const email = optional(b.email), username = optional(b.username), password = optional(b.password);
  const bio = optional(b.bio, true), image = optional(b.image, true);
  const hash = password === null ? null : await passwordHash(password);
  const row = first((await pool.query<UserRow>(`UPDATE users SET email=COALESCE($2,email),username=COALESCE($3,username),
    password_hash=COALESCE($4,password_hash),bio=COALESCE($5,bio),image=COALESCE($6,image) WHERE id=$1 RETURNING ${userColumns}`,
  [auth.id, email, username, hash, bio, image])).rows, 401);
  sendJson(response, 200, { user: user(row, auth.token) });
};
export const getProfile: Handler = async ({ request, response, params }) => {
  const auth = await authenticate(request, false);
  const row = first((await pool.query<Profile>(`SELECT username,bio,image,
    EXISTS(SELECT 1 FROM follows WHERE follower_id=$1 AND followee_id=u.id) following FROM users u WHERE username=$2`,
  [auth.id, params.username])).rows);
  sendJson(response, 200, { profile: profile(row) });
};
async function follow(context: RequestContext, following: boolean): Promise<void> {
  const { request, response, params } = context;
  const auth = await authenticate(request);
  const row = first((await pool.query<UserRow>('SELECT id,username,bio,image FROM users WHERE username=$1', [params.username])).rows);
  await pool.query(following ? 'INSERT INTO follows(follower_id,followee_id) VALUES($1,$2) ON CONFLICT DO NOTHING'
    : 'DELETE FROM follows WHERE follower_id=$1 AND followee_id=$2', [auth.id, row.id]);
  sendJson(response, 200, { profile: profile({ ...row, following }) });
}
export const followProfile: Handler = c => follow(c, true);
export const unfollowProfile: Handler = c => follow(c, false);

async function list(context: RequestContext, feed: boolean): Promise<void> {
  const { request, response, url } = context;
  const { id } = await authenticate(request, feed);
  const { limit, offset } = pagination(url);
  const tag = url.searchParams.get('tag'), author = url.searchParams.get('author'), favorited = url.searchParams.get('favorited');
  let source = 'articles a';
  let where = 'TRUE';
  let pageId = 'a.id';
  const values: (string | number)[] = [id, limit, offset];
  let countValues: string[] = [];
  if (feed) {
    where = 'a.author_id IN (SELECT followee_id FROM follows WHERE follower_id=$1)';
    countValues = [id];
  } else if (tag) {
    source = 'article_tags at'; pageId = 'at.article_id';
    where = 'at.tag_id=(SELECT id FROM tags WHERE name=$4)';
    values.push(tag); countValues = [tag];
  } else if (author) {
    where = 'a.author_id=(SELECT id FROM users WHERE username=$4)';
    values.push(author); countValues = [author];
  } else if (favorited) {
    source = 'favorites f'; pageId = 'f.article_id';
    where = 'f.user_id=(SELECT id FROM users WHERE username=$4)';
    values.push(favorited); countValues = [favorited];
  }
  // Page link-table/feed IDs before enrichment. Global/author lists already
  // walk the article indexes directly, avoiding a redundant PK lookup.
  // Link-table PKs and FKs make counts equivalent without joining articles.
  const page = feed
    ? `SELECT x.id FROM follows fo CROSS JOIN LATERAL
        (SELECT a2.id FROM articles a2 WHERE a2.author_id=fo.followee_id
         ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x
       WHERE fo.follower_id=$1 ORDER BY x.id DESC LIMIT $2 OFFSET $3`
    : `SELECT ${pageId} FROM ${source} WHERE ${where} ORDER BY ${pageId} DESC LIMIT $2 OFFSET $3`;
  const pageSql = feed || source !== 'articles a'
    ? `${articleSelect(false)} WHERE a.id IN (${page}) ORDER BY a.id DESC`
    : `${articleSelect(false)} WHERE ${where} ORDER BY a.id DESC LIMIT $2 OFFSET $3`;
  const rows = (await pool.query<ArticleRow>(pageSql, values)).rows;
  const countWhere = where.replaceAll('$4', '$1');
  const count = first((await pool.query<{ count: string }>(`SELECT count(*) FROM
    (SELECT 1 FROM ${source} WHERE ${countWhere} LIMIT 1000) counted`, countValues)).rows);
  sendJson(response, 200, { articles: rows.map(r => article(r, false)), articlesCount: safeInteger(count.count) });
}
export const listArticles: Handler = c => list(c, false);
export const getArticleFeed: Handler = c => list(c, true);
export const getArticle: Handler = async ({ request, response, params }) => {
  const { id } = await authenticate(request, false);
  const row = first((await pool.query<ArticleRow>(`${articleSelect(true)} WHERE a.slug=$2`, [id, params.slug])).rows);
  sendJson(response, 200, { article: article(row, true) });
};
export const createArticle: Handler = async ({ request, response }) => {
  const auth = await authenticate(request);
  const b = await readBody(request, 'article');
  const title = string(b.title), description = string(b.description), body = string(b.body);
  const rawTags: unknown = b.tagList ?? [];
  if (!Array.isArray(rawTags)) fail(422, 'Invalid tagList');
  const tags = (rawTags as unknown[]).map(t => string(t));
  const id = await transaction(async client => {
    const row = first((await client.query<{ id: string }>(`INSERT INTO articles(id,slug,author_id,title,description,body)
      SELECT n.id,${slugify('$2')}||'-'||n.id,$1,$2,$3,$4
      FROM (SELECT nextval(pg_get_serial_sequence('articles','id')) id) n RETURNING id`, [auth.id, title, description, body])).rows);
    if (tags.length) {
      await client.query('INSERT INTO tags(name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT(name) DO NOTHING', [tags]);
      await client.query('INSERT INTO article_tags(article_id,tag_id) SELECT $1,id FROM tags WHERE name=ANY($2::text[])', [row.id, tags]);
    }
    return row.id;
  });
  sendJson(response, 201, { article: await articleById(id, auth.id) });
};
export const updateArticle: Handler = async ({ request, response, params }) => {
  const auth = await authenticate(request);
  const b = await readBody(request, 'article');
  const title = optional(b.title), description = optional(b.description), body = optional(b.body);
  const row = await articleIdentity(params.slug);
  owner(row.author_id, auth.id);
  await pool.query(`UPDATE articles SET title=COALESCE($2,title),description=COALESCE($3,description),body=COALESCE($4,body),
    slug=CASE WHEN $2::text IS NULL THEN slug ELSE ${slugify('$2')}||'-'||id END,updated_at=now() WHERE id=$1`, [row.id, title, description, body]);
  sendJson(response, 200, { article: await articleById(row.id, auth.id) });
};
export const deleteArticle: Handler = async ({ request, response, params }) => {
  const auth = await authenticate(request);
  const row = await articleIdentity(params.slug);
  owner(row.author_id, auth.id);
  await pool.query('DELETE FROM articles WHERE id=$1', [row.id]);
  response.writeHead(204).end();
};
async function favorite(context: RequestContext, add: boolean): Promise<void> {
  const { request, response, params } = context;
  const auth = await authenticate(request);
  const row = await articleIdentity(params.slug);
  await pool.query(add ? 'INSERT INTO favorites(user_id,article_id) VALUES($1,$2) ON CONFLICT DO NOTHING'
    : 'DELETE FROM favorites WHERE user_id=$1 AND article_id=$2', [auth.id, row.id]);
  sendJson(response, 200, { article: await articleById(row.id, auth.id) });
}
export const favoriteArticle: Handler = c => favorite(c, true);
export const unfavoriteArticle: Handler = c => favorite(c, false);
export const listComments: Handler = async ({ request, response, params }) => {
  const auth = await authenticate(request, false);
  const row = await articleIdentity(params.slug);
  const comments = (await pool.query<CommentRow>(`SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image,
    EXISTS(SELECT 1 FROM follows WHERE follower_id=$1 AND followee_id=c.author_id) following
    FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=$2 ORDER BY c.created_at DESC,c.id DESC LIMIT 100`, [auth.id, row.id])).rows;
  sendJson(response, 200, { comments: comments.map(comment) });
};
export const createComment: Handler = async ({ request, response, params }) => {
  const auth = await authenticate(request);
  const body = string((await readBody(request, 'comment')).body);
  const row = await articleIdentity(params.slug);
  // Map before commit so an unrepresentable JSON comment ID rolls back the write.
  const result = await transaction(async client => {
    const created = first((await client.query<CommentRow>(`WITH c AS (
      INSERT INTO comments(article_id,author_id,body) VALUES($1,$2,$3) RETURNING *)
      SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image,false following
      FROM c JOIN users u ON u.id=c.author_id`, [row.id, auth.id, body])).rows);
    return comment(created);
  });
  sendJson(response, 201, { comment: result });
};
export const deleteComment: Handler = async ({ request, response, params }) => {
  const auth = await authenticate(request);
  if (!validId(params.id)) fail(404, 'Comment not found');
  const row = first((await pool.query<{ author_id: string }>(`SELECT c.author_id FROM comments c JOIN articles a ON a.id=c.article_id
    WHERE c.id=$1 AND a.slug=$2`, [params.id, params.slug])).rows);
  owner(row.author_id, auth.id);
  await pool.query('DELETE FROM comments WHERE id=$1', [params.id]);
  response.writeHead(204).end();
};
export const listTags: Handler = async ({ response }) => {
  const rows = (await pool.query<{ name: string }>('SELECT name FROM tags ORDER BY name')).rows;
  sendJson(response, 200, { tags: rows.map(r => r.name) });
};
