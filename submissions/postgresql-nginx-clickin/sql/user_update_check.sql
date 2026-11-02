-- PUT /api/user, 1/2: any of email, username, password, bio, image. Absent or null leaves it unchanged;
-- otherwise a string (email, username and password non-empty, password <= 72 bytes).
SELECT CASE WHEN NOT ok THEN 422 END AS status,
       '{"errors":{"body":["invalid user fields"]}}' AS body,
       u->>'email' AS new_email, u->>'username' AS new_username, u->>'bio' AS new_bio, u->>'image' AS new_image,
       CASE WHEN ok THEN u->>'password' END AS bcrypt_password
  FROM (SELECT u, u IS NOT NULL AND coalesce(
                 (SELECT bool_and(CASE WHEN json_typeof(u->f) IS NULL OR json_typeof(u->f) = 'null' THEN true
                                       WHEN json_typeof(u->f) <> 'string' THEN false
                                       WHEN f IN ('email', 'username', 'password') AND u->>f = '' THEN false
                                       WHEN f = 'password' THEN octet_length(u->>f) <= 72
                                       ELSE true END)
                    FROM unnest(ARRAY['email', 'username', 'password', 'bio', 'image']) f), false) AS ok
          FROM (SELECT CASE WHEN json_typeof(:req::json) = 'object' AND json_typeof(:req::json->'user') = 'object'
                            THEN :req::json->'user' END AS u) w) v
