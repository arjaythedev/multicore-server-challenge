WITH r AS (SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(v, slug, ord)),
 t AS (SELECT r.ord, r.v, a.id FROM r CROSS JOIN LATERAL (SELECT id FROM articles WHERE slug = r.slug) a),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT v, id FROM t ON CONFLICT DO NOTHING)
SELECT id, ord FROM t
