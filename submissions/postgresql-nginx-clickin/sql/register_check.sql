-- POST /api/users, 1/4: {"user": {"username", "email", "password"}}, all non-empty strings (password <= 72 bytes,
-- bcrypt's limit). A body that isn't JSON fails the cast: SQLSTATE 22P02, which the module answers with 422.
SELECT CASE WHEN NOT ok THEN 422 END AS status,
       '{"errors":{"body":["username, email and password are required"]}}' AS body,
       u->>'username' AS username, u->>'email' AS email,
       CASE WHEN ok THEN u->>'password' END AS bcrypt_password
  FROM (SELECT u, coalesce(json_typeof(u->'username') = 'string' AND u->>'username' <> ''
                       AND json_typeof(u->'email') = 'string' AND u->>'email' <> ''
                       AND json_typeof(u->'password') = 'string' AND u->>'password' <> ''
                       AND octet_length(u->>'password') <= 72, false) AS ok
          FROM (SELECT CASE WHEN json_typeof(:req::json) = 'object' AND json_typeof(:req::json->'user') = 'object'
                            THEN :req::json->'user' END AS u) w) v
