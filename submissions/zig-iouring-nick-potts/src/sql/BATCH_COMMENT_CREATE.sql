WITH r AS MATERIALIZED (SELECT nextval('comments_id_seq'::regclass) AS id, a.id AS article_id, x.author, x.body, x.ord
       FROM unnest($1::text[], $2::bigint[], $3::text[]) WITH ORDINALITY AS x(slug, author, body, ord)
       CROSS JOIN LATERAL (SELECT id FROM articles WHERE slug = x.slug) a),
 c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, article_id, author, body FROM r
       RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, r.ord
FROM c JOIN r ON r.id = c.id JOIN users u ON u.id = c.author_id
