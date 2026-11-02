-- GET /api/articles: one page and the capped count. Only the first of tag, author, favorited applies, and an
-- empty value (?tag=) is no filter. Each branch is gated on parameters alone, so with generic plans the
-- branches that don't apply are one-time filters and never touch a table.
WITH ids AS (
  (SELECT a.id FROM articles a
    WHERE nullif(:tag::text, '') IS NULL AND nullif(:author::text, '') IS NULL AND nullif(:favorited::text, '') IS NULL
    ORDER BY a.id DESC LIMIT :page_limit::int OFFSET :page_offset::int)
  UNION ALL
  (SELECT at.article_id FROM article_tags at
    WHERE nullif(:tag::text, '') IS NOT NULL
      AND at.tag_id = (SELECT t.id FROM tags t WHERE t.name = :tag::text)
    ORDER BY at.article_id DESC LIMIT :page_limit::int OFFSET :page_offset::int)
  UNION ALL
  (SELECT a.id FROM articles a
    WHERE nullif(:tag::text, '') IS NULL AND nullif(:author::text, '') IS NOT NULL
      AND a.author_id = (SELECT au.id FROM users au WHERE au.username = :author::text)
    ORDER BY a.id DESC LIMIT :page_limit::int OFFSET :page_offset::int)
  UNION ALL
  (SELECT fa.article_id FROM favorites fa
    WHERE nullif(:tag::text, '') IS NULL AND nullif(:author::text, '') IS NULL AND nullif(:favorited::text, '') IS NOT NULL
      AND fa.user_id = (SELECT fu.id FROM users fu WHERE fu.username = :favorited::text)
    ORDER BY fa.article_id DESC LIMIT :page_limit::int OFFSET :page_offset::int))
SELECT 200 AS status,
       jsonb_build_object(
         'articles', coalesce((SELECT jsonb_agg({{_article}} - 'body' ORDER BY a.id DESC)
                                 FROM articles a JOIN users u ON u.id = a.author_id
                                WHERE a.id IN (SELECT id FROM ids)), '[]'),
         'articlesCount',
           CASE WHEN nullif(:tag::text, '') IS NOT NULL THEN
                  (SELECT count(*) FROM (SELECT 1 FROM article_tags at
                     WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = :tag::text) LIMIT 1000) s)
                WHEN nullif(:author::text, '') IS NOT NULL THEN
                  (SELECT count(*) FROM (SELECT 1 FROM articles a
                     WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = :author::text) LIMIT 1000) s)
                WHEN nullif(:favorited::text, '') IS NOT NULL THEN
                  (SELECT count(*) FROM (SELECT 1 FROM favorites fa
                     WHERE fa.user_id = (SELECT fu.id FROM users fu WHERE fu.username = :favorited::text) LIMIT 1000) s)
                ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s) END
       )::text AS body
