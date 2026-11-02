-- POST /api/articles/:slug/comments, 1/2: {"comment": {"body"}}, a non-empty string. Checked before the slug.
SELECT CASE WHEN NOT ok THEN 422 END AS status, '{"errors":{"body":["body is required"]}}' AS body,
       cm->>'body' AS comment_body
  FROM (SELECT cm, coalesce(json_typeof(cm->'body') = 'string' AND cm->>'body' <> '', false) AS ok
          FROM (SELECT CASE WHEN json_typeof(:req::json) = 'object' AND json_typeof(:req::json->'comment') = 'object'
                            THEN :req::json->'comment' END AS cm) w) v
