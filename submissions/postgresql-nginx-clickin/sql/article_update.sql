-- PUT /api/articles/:slug, 2/3: 404 for an unknown slug, 403 unless the viewer wrote it. A new title gets a new slug.
WITH a AS (SELECT id, author_id FROM articles WHERE slug = :slug::text),
     up AS (UPDATE articles SET title = COALESCE(:title::text, title),
                                description = COALESCE(:description::text, description),
                                body = COALESCE(:article_body::text, body),
                                slug = CASE WHEN :title::text IS NULL THEN slug
                                            ELSE trim(both '-' from lower(regexp_replace(:title::text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
                                updated_at = now()
             WHERE id = (SELECT id FROM a WHERE author_id = :viewer::bigint))
SELECT CASE WHEN a.id IS NULL THEN 404 WHEN a.author_id <> :viewer::bigint THEN 403 END AS status,
       CASE WHEN a.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE '{"errors":{"body":["only the author can change an article"]}}' END AS body,
       a.id AS article_id
  FROM (SELECT 1) one LEFT JOIN a ON true
