-- Who is asking, for one request row q: verifies the HS256 JWT in q.authz ("Token <jwt>" or NULL), in SQL.
-- In: q.authz, :hmac_ipad and :hmac_opad (from start.sh), :required (non-NULL: anonymous is a 401).
-- Out: viewer (0 when anonymous) and token, or status 401. Used as a LATERAL subquery by _auth.sql (one request)
-- and by the *_batch.sql files (one row per request).
-- The signature is checked on the raw text first; the header and payload are only decoded once it matches, so
-- garbage never reaches a cast that could fail. "OFFSET 0" keeps the planner from pulling a subquery up into the
-- next one: pulled up, each reference to sig.signed or jose.payload would recompute the HMAC or the JSON parse.
SELECT CASE WHEN q.authz IS NULL THEN CASE WHEN :required::text IS NOT NULL THEN 401 END
            WHEN claims.viewer IS NULL THEN 401 END AS status,
       '{"errors":{"body":["missing or invalid token"]}}' AS body,
       coalesce(claims.viewer, 0) AS viewer,
       jwt.token
  FROM (SELECT CASE WHEN q.authz LIKE 'Token %' THEN substr(q.authz, 7) END AS token OFFSET 0) jwt
 CROSS JOIN {{_hmac_keys}} hmac
 CROSS JOIN LATERAL (
   SELECT split_part(jwt.token, '.', 1) AS h, split_part(jwt.token, '.', 2) AS p,
          coalesce(jwt.token ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$', false)
          AND encode(sha256(hmac.opad || sha256(hmac.ipad || convert_to(split_part(jwt.token, '.', 1) || '.' ||
                                                                        split_part(jwt.token, '.', 2), 'UTF8'))), 'base64')
              = translate(split_part(jwt.token, '.', 3), '-_', '+/') || '=' AS signed
   OFFSET 0) sig
 CROSS JOIN LATERAL (
   SELECT CASE WHEN sig.signed THEN convert_from(decode(rpad(translate(sig.h, '-_', '+/'), (length(sig.h) + 3) / 4 * 4, '='), 'base64'), 'UTF8')::json END AS header,
          CASE WHEN sig.signed THEN convert_from(decode(rpad(translate(sig.p, '-_', '+/'), (length(sig.p) + 3) / 4 * 4, '='), 'base64'), 'UTF8')::json END AS payload
   OFFSET 0) jose
 CROSS JOIN LATERAL (
   SELECT CASE WHEN json_typeof(jose.header) = 'object' AND jose.header->>'alg' = 'HS256'
                AND json_typeof(jose.payload) = 'object'
                AND json_typeof(jose.payload->'exp') = 'number'
                AND json_typeof(jose.payload->'sub') = 'string'
               THEN CASE WHEN (jose.payload->>'exp')::numeric > extract(epoch FROM now())
                          AND jose.payload->>'sub' ~ '^[1-9][0-9]{0,17}$'
                         THEN (jose.payload->>'sub')::bigint END
          END AS viewer) claims
