import type { Auth } from "./auth";
import { withDatabase, type Connection } from "./db";
import { fail, input, pagination, stringField, type Context } from "./http";
import { article, type ArticleRow } from "./models";

// Reference SELECTs from SPEC.md; only fixed SQL fragments are concatenated below.
const select = (full = false) => `SELECT a.id, a.slug, a.title, a.description, ${full ? "a.body," : ""} a.created_at, a.updated_at,
  ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
    WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
  (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
  EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
  u.username, u.bio, u.image,
  EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a JOIN users u ON u.id = a.author_id`;

const listSelect = select();
const fullSelect = select(true);
const pageOrder = " ORDER BY a.id DESC LIMIT $2 OFFSET $3";

async function byId(db: Connection, viewer: string, id: string) {
  const [row] = await db.unsafe(fullSelect + " WHERE a.id = $2", [viewer, id]);
  if (!row) fail(404, "Article not found");
  return article(row);
}

export async function listArticles(request: Request, _context: Context, auth: Auth) {
  const url = new URL(request.url);
  const { limit, offset } = pagination(url);
  const tag = url.searchParams.get("tag");
  const author = url.searchParams.get("author");
  const favorited = url.searchParams.get("favorited");
  let page = listSelect + pageOrder;
  let count = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s";
  const values: string[] = [auth.viewer, limit, offset];
  const countValues: string[] = [];
  if (tag) {
    page = listSelect + ` WHERE a.id IN (SELECT at.article_id FROM article_tags at
      WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
      ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC`;
    count = `SELECT count(*) FROM (SELECT 1 FROM article_tags at
      WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s`;
    values.push(tag); countValues.push(tag);
  } else if (author) {
    page = listSelect + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)" + pageOrder;
    count = `SELECT count(*) FROM (SELECT 1 FROM articles a
      WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s`;
    values.push(author); countValues.push(author);
  } else if (favorited) {
    page = listSelect + ` WHERE a.id IN (SELECT f.article_id FROM favorites f
      WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)
      ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC`;
    count = `SELECT count(*) FROM (SELECT 1 FROM favorites f
      WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s`;
    values.push(favorited); countValues.push(favorited);
  }
  return withDatabase(async db => {
    const rows = await db.unsafe(page, values);
    const [total] = await db.unsafe(count, countValues);
    return Response.json({ articles: rows.map((row: ArticleRow) => article(row)), articlesCount: Number(total.count) });
  });
}

export async function feed(request: Request, _context: Context, auth: Auth) {
  const { limit, offset } = pagination(new URL(request.url));
  return withDatabase(async db => {
    const rows = await db.unsafe(listSelect + ` WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
      (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC
        LIMIT ($2::bigint + LEAST($3::bigint, 9223372036854775807 - $2::bigint))) x
      WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC`, [auth.viewer, limit, offset]);
    const [total] = await db`SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN
      (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ${auth.viewer}) LIMIT 1000) s`;
    return Response.json({ articles: rows.map((row: ArticleRow) => article(row)), articlesCount: Number(total.count) });
  });
}

export async function getArticle(_request: Request, { params }: Context, auth: Auth) {
  return withDatabase(async db => {
    const [row] = await db.unsafe(fullSelect + " WHERE a.slug = $2", [auth.viewer, params.slug]);
    if (!row) fail(404, "Article not found");
    return Response.json({ article: article(row) });
  });
}

export async function createArticle(request: Request, _context: Context, auth: Auth) {
  const fields = await input(request, "article");
  const title = stringField(fields, "title")!;
  const description = stringField(fields, "description")!;
  const body = stringField(fields, "body")!;
  const tags = fields.tagList ?? [];
  if (!Array.isArray(tags) || tags.some(tag => typeof tag !== "string" || !tag.length || tag.includes("\0"))) {
    fail(422, "Invalid tagList");
  }
  return withDatabase(async db => {
    const id = await db.begin(async tx => {
      const [row] = await tx`INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, trim(both '-' from lower(regexp_replace(${title}, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
          ${auth.viewer}, ${title}, ${description}, ${body}
        FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id`;
      if (tags.length) {
        // Lock shared tag names in a stable order when articles are created concurrently.
        await tx`INSERT INTO tags (name) SELECT DISTINCT unnest(${tx.array(tags, "TEXT")}) ORDER BY 1 ON CONFLICT (name) DO NOTHING`;
        await tx`INSERT INTO article_tags (article_id, tag_id) SELECT ${row.id}, t.id FROM tags t
          WHERE t.name = ANY(${tx.array(tags, "TEXT")})`;
      }
      return row.id;
    });
    return Response.json({ article: await byId(db, auth.viewer, id) }, { status: 201 });
  });
}

export async function updateArticle(request: Request, { params }: Context, auth: Auth) {
  const fields = await input(request, "article");
  const title = stringField(fields, "title", false);
  const description = stringField(fields, "description", false);
  const body = stringField(fields, "body", false);
  return withDatabase(async db => {
    const id = await db.begin(async tx => {
      const [row] = await tx`SELECT id, author_id FROM articles WHERE slug = ${params.slug} FOR UPDATE`;
      if (!row) fail(404, "Article not found");
      if (String(row.author_id) !== auth.viewer) fail(403, "Not the author");
      await tx`UPDATE articles SET title = COALESCE(${title}, title), description = COALESCE(${description}, description),
        body = COALESCE(${body}, body),
        slug = CASE WHEN ${title}::text IS NULL THEN slug ELSE
          trim(both '-' from lower(regexp_replace(${title}, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
        updated_at = now() WHERE id = ${row.id}`;
      return row.id;
    });
    return Response.json({ article: await byId(db, auth.viewer, id) });
  });
}

export async function deleteArticle(_request: Request, { params }: Context, auth: Auth) {
  return withDatabase(async db => {
    await db.begin(async tx => {
      const [row] = await tx`SELECT id, author_id FROM articles WHERE slug = ${params.slug} FOR UPDATE`;
      if (!row) fail(404, "Article not found");
      if (String(row.author_id) !== auth.viewer) fail(403, "Not the author");
      await tx`DELETE FROM articles WHERE id = ${row.id}`;
    });
    return new Response(null, { status: 204 });
  });
}

export async function favorite(request: Request, { params }: Context, auth: Auth) {
  return withDatabase(async db => {
    const id = await db.begin(async tx => {
      const [row] = await tx`SELECT id FROM articles WHERE slug = ${params.slug} FOR KEY SHARE`;
      if (!row) fail(404, "Article not found");
      if (request.method === "POST") {
        await tx`INSERT INTO favorites (user_id, article_id) VALUES (${auth.viewer}, ${row.id}) ON CONFLICT DO NOTHING`;
      } else {
        await tx`DELETE FROM favorites WHERE user_id = ${auth.viewer} AND article_id = ${row.id}`;
      }
      return row.id;
    });
    return Response.json({ article: await byId(db, auth.viewer, id) });
  });
}
