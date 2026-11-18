-- A fresh token for :user_id: {"sub":"<id>","iat":now,"exp":now+30 days}, signed HS256 in SQL.
SELECT h || '.' || p || '.' ||
       rtrim(translate(encode(sha256(hmac.opad || sha256(hmac.ipad || convert_to(h || '.' || p, 'UTF8'))), 'base64'), '+/', '-_'), '=')
       AS token
  FROM (SELECT 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9' AS h,  -- {"alg":"HS256","typ":"JWT"}
               rtrim(translate(replace(encode(convert_to(
                 '{"sub":"' || :user_id::bigint || '","iat":' || n || ',"exp":' || (n + 2592000) || '}', 'UTF8'), 'base64'),
                 E'\n', ''), '+/', '-_'), '=') AS p
          FROM (SELECT floor(extract(epoch FROM now()))::bigint AS n) clock) jwt
 CROSS JOIN {{_hmac_keys}} hmac
