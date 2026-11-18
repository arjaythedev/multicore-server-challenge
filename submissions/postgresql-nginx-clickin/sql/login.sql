-- POST /api/users/login, 1/3: find the user by email. The module then compares :check_password with
-- :check_hash using bcrypt and answers 401 on a mismatch.
SELECT CASE WHEN NOT v.ok THEN 422 WHEN u.id IS NULL THEN 401 END AS status,
       CASE WHEN NOT v.ok THEN '{"errors":{"body":["email and password are required"]}}'
            ELSE '{"errors":{"body":["invalid email or password"]}}' END AS body,
       u.id AS user_id, u.username, u.email, u.bio, u.image,
       v.password AS check_password, u.password_hash AS check_hash
  FROM (SELECT coalesce(json_typeof(c->'email') = 'string' AND c->>'email' <> ''
                    AND json_typeof(c->'password') = 'string' AND c->>'password' <> '', false) AS ok,
               c->>'email' AS email, c->>'password' AS password
          FROM (SELECT CASE WHEN json_typeof(:req::json) = 'object' AND json_typeof(:req::json->'user') = 'object'
                            THEN :req::json->'user' END AS c) w) v
  LEFT JOIN users u ON v.ok AND u.email = v.email
