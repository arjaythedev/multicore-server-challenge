import type { Auth } from "./auth";
import { withDatabase } from "./db";
import { commentId, fail, input, stringField, type Context } from "./http";
import { comment, type CommentRow } from "./models";

export async function listComments(_request: Request, { params }: Context, auth: Auth) {
  return withDatabase(async db => {
    const [row] = await db`SELECT id FROM articles WHERE slug = ${params.slug}`;
    if (!row) fail(404, "Article not found");
    const rows = await db`SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
      EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ${auth.viewer} AND fo.followee_id = c.author_id) AS following
      FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = ${row.id}
      ORDER BY c.created_at DESC, c.id DESC LIMIT 100`;
    return Response.json({ comments: rows.map((row: CommentRow) => comment(row)) });
  });
}

export async function createComment(request: Request, { params }: Context, auth: Auth) {
  const body = stringField(await input(request, "comment"), "body")!;
  return withDatabase(async db => {
    const row = await db.begin(async tx => {
      const [article] = await tx`SELECT id FROM articles WHERE slug = ${params.slug} FOR KEY SHARE`;
      if (!article) fail(404, "Article not found");
      const [row] = await tx`WITH c AS (INSERT INTO comments (article_id, author_id, body)
        VALUES (${article.id}, ${auth.viewer}, ${body}) RETURNING id, body, created_at, updated_at, author_id)
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
        FROM c JOIN users u ON u.id = c.author_id`;
      return row;
    });
    return Response.json({ comment: comment(row) }, { status: 201 });
  });
}

export async function deleteComment(_request: Request, { params }: Context, auth: Auth) {
  const id = commentId(params.id);
  return withDatabase(async db => {
    await db.begin(async tx => {
      const [row] = await tx`SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
        WHERE c.id = ${id} AND a.slug = ${params.slug} FOR UPDATE OF c`;
      if (!row) fail(404, "Comment not found");
      if (String(row.author_id) !== auth.viewer) fail(403, "Not the author");
      await tx`DELETE FROM comments WHERE id = ${id}`;
    });
    return new Response(null, { status: 204 });
  });
}
