-- Who is asking, for one request: :authorization (NULL when the header is absent) checked by _jwt.sql.
-- Out: viewer (0 when anonymous) and token, or status 401.
SELECT x.status, x.body, x.viewer, x.token
  FROM (SELECT :authorization::text AS authz) q CROSS JOIN LATERAL ({{_jwt}}) x
