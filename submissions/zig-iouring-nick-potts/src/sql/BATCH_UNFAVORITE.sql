WITH r AS (SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(v, slug, ord)),
 t AS (SELECT r.ord, r.v, a.id FROM r CROSS JOIN LATERAL (SELECT id FROM articles WHERE slug = r.slug) a),
 w AS (DELETE FROM favorites f USING t WHERE f.user_id = t.v AND f.article_id = t.id)
SELECT id, ord FROM t
