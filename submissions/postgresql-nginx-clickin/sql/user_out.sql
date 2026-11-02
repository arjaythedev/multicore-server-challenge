-- POST /api/users and /api/users/login, last step: {"user": User} with the token from jwt_sign.sql.
SELECT :ok_status::int AS status, {{_user}} AS body
  FROM (SELECT :email::text AS email, :token::text AS token, :username::text AS username,
               :bio::text AS bio, :image::text AS image) u
