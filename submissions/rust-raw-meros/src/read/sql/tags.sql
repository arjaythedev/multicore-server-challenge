-- All tags in name order: the answer to GET /api/tags, and the id -> name table that the article statements need
-- (they return tag ids; the position in this order is the sort key of an article's tagList). Runs once per batch.
SELECT id::int8, name FROM tags ORDER BY name
