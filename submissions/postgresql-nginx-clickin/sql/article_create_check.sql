-- POST /api/articles, 1/6: title, description and body are non-empty strings; tagList, if there, is an array of
-- non-empty strings. Out: the fields, and tag_list as a text[] literal.
SELECT CASE WHEN NOT ok THEN 422 END AS status,
       '{"errors":{"body":["title, description and body are required"]}}' AS body,
       art->>'title' AS title, art->>'description' AS description, art->>'body' AS article_body,
       CASE WHEN ok THEN ARRAY(SELECT json_array_elements_text(
                           CASE WHEN json_typeof(art->'tagList') = 'array' THEN art->'tagList' ELSE '[]' END)) END AS tag_list
  FROM (SELECT art, art IS NOT NULL AND coalesce(
                 json_typeof(art->'title') = 'string' AND art->>'title' <> ''
             AND json_typeof(art->'description') = 'string' AND art->>'description' <> ''
             AND json_typeof(art->'body') = 'string' AND art->>'body' <> ''
             AND CASE WHEN art->'tagList' IS NULL OR json_typeof(art->'tagList') = 'null' THEN true
                      WHEN json_typeof(art->'tagList') <> 'array' THEN false
                      ELSE (SELECT coalesce(bool_and(json_typeof(e) = 'string' AND e #>> '{}' <> ''), true)
                              FROM json_array_elements(art->'tagList') e) END, false) AS ok
          FROM (SELECT CASE WHEN json_typeof(:req::json) = 'object' AND json_typeof(:req::json->'article') = 'object'
                            THEN :req::json->'article' END AS art) w) v
