-- GET /api/articles, in one statement: who is asking (401), ?limit/?offset (422), then one page and the capped
-- count. Only the first of tag, author, favorited applies, and an empty value (?tag=) is no filter. Each page
-- branch is gated on parameters alone, so in the generic plan the branches that don't apply are one-time
-- filters and never touch a table. The page CTEs only run when the CASE below reaches them.
WITH auth AS MATERIALIZED ({{_auth}}),
page AS MATERIALIZED ({{_page}}),
ids AS (
  (SELECT a.id FROM articles a
    WHERE nullif(:tag::text, '') IS NULL AND nullif(:author::text, '') IS NULL AND nullif(:favorited::text, '') IS NULL
    ORDER BY a.id DESC LIMIT (SELECT page_limit FROM page) OFFSET (SELECT page_offset FROM page))
  UNION ALL
  (SELECT at.article_id FROM article_tags at
    WHERE nullif(:tag::text, '') IS NOT NULL
      AND at.tag_id = (SELECT t.id FROM tags t WHERE t.name = :tag::text)
    ORDER BY at.article_id DESC LIMIT (SELECT page_limit FROM page) OFFSET (SELECT page_offset FROM page))
  UNION ALL
  (SELECT a.id FROM articles a
    WHERE nullif(:tag::text, '') IS NULL AND nullif(:author::text, '') IS NOT NULL
      AND a.author_id = (SELECT au.id FROM users au WHERE au.username = :author::text)
    ORDER BY a.id DESC LIMIT (SELECT page_limit FROM page) OFFSET (SELECT page_offset FROM page))
  UNION ALL
  (SELECT fa.article_id FROM favorites fa
    WHERE nullif(:tag::text, '') IS NULL AND nullif(:author::text, '') IS NULL AND nullif(:favorited::text, '') IS NOT NULL
      AND fa.user_id = (SELECT fu.id FROM users fu WHERE fu.username = :favorited::text)
    ORDER BY fa.article_id DESC LIMIT (SELECT page_limit FROM page) OFFSET (SELECT page_offset FROM page)))
SELECT coalesce(auth.status, page.status, 200) AS status,
       CASE WHEN auth.status IS NOT NULL THEN auth.body
            WHEN page.status IS NOT NULL THEN page.body
            ELSE jsonb_build_object(
              'articles', coalesce((SELECT jsonb_agg({{_article_list}} ORDER BY a.id DESC)
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
            )::text END AS body
  FROM auth, page
