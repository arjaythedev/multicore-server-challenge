-- PUT /api/articles/:slug, 1/3: any of title, description, body; absent or null leaves it unchanged, otherwise a
-- non-empty string.
SELECT CASE WHEN NOT ok THEN 422 END AS status,
       '{"errors":{"body":["title, description and body must be non-empty strings"]}}' AS body,
       art->>'title' AS title, art->>'description' AS description, art->>'body' AS article_body
  FROM (SELECT art, art IS NOT NULL AND coalesce(
                 (SELECT bool_and(CASE WHEN json_typeof(art->f) IS NULL OR json_typeof(art->f) = 'null' THEN true
                                       ELSE json_typeof(art->f) = 'string' AND art->>f <> '' END)
                    FROM unnest(ARRAY['title', 'description', 'body']) f), false) AS ok
          FROM (SELECT CASE WHEN json_typeof(:req::json) = 'object' AND json_typeof(:req::json->'article') = 'object'
                            THEN :req::json->'article' END AS art) w) v
