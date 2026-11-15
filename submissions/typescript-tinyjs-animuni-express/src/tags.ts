import { withDatabase } from "./db";

export async function listTags() {
  return withDatabase(async db => {
    const rows = await db`SELECT name FROM tags ORDER BY name`;
    return Response.json({ tags: rows.map((row: { name: string }) => row.name) });
  });
}
