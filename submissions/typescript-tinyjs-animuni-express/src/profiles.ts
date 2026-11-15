import type { Auth } from "./auth";
import { withDatabase } from "./db";
import { fail, type Context } from "./http";
import { profile } from "./models";

export async function getProfile(_request: Request, { params }: Context, auth: Auth) {
  return withDatabase(async db => {
    const [row] = await db`SELECT u.id, u.username, u.bio, u.image,
      EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ${auth.viewer} AND fo.followee_id = u.id) AS following
      FROM users u WHERE u.username = ${params.username}`;
    if (!row) fail(404, "Profile not found");
    return Response.json({ profile: profile(row) });
  });
}

export async function follow(request: Request, { params }: Context, auth: Auth) {
  const following = request.method === "POST";
  return withDatabase(async db => {
    const row = await db.begin(async tx => {
      const [row] = await tx`SELECT id, username, bio, image FROM users WHERE username = ${params.username} FOR KEY SHARE`;
      if (!row) fail(404, "Profile not found");
      if (following) {
        await tx`INSERT INTO follows (follower_id, followee_id) VALUES (${auth.viewer}, ${row.id}) ON CONFLICT DO NOTHING`;
      } else {
        await tx`DELETE FROM follows WHERE follower_id = ${auth.viewer} AND followee_id = ${row.id}`;
      }
      return row;
    });
    return Response.json({ profile: profile({ ...row, following }) });
  });
}
