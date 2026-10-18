-- Conduit (RealWorld) API inside nginx's content phase. Postgres through pgmoon on nginx's non-blocking
-- sockets, one connection pool per worker; HS256 JWTs through OpenSSL's HMAC (FFI); bcrypt in a thread pool
-- (crypt.lua). Responses are built by concatenation; only user text goes through cjson's string escaping.
local ffi = require "ffi"
local pgmoon = require "pgmoon"
local buffered = require "pgbuf"
local b64 = require "ngx.base64"
local cjson = require "cjson"

local json = cjson.new()
json.encode_escape_forward_slash(false)
json.decode_array_with_array_mt(true)
local array_mt, json_null = cjson.array_mt, cjson.null
local safe_decode = require("cjson.safe").new()
safe_decode.decode_array_with_array_mt(true)

local ngx = ngx
local type, tonumber, tostring, select, pcall = type, tonumber, tostring, select, pcall
local concat, insert = table.concat, table.insert
local enc = json.encode

ffi.cdef [[
typedef struct evp_md_st EVP_MD;
const EVP_MD *EVP_sha256(void);
unsigned char *HMAC(const EVP_MD *md, const void *key, int key_len, const unsigned char *d, size_t n,
                    unsigned char *out, unsigned int *out_len);
]]
-- OpenResty's nginx links its own OpenSSL, so HMAC is already in the process
local crypto = pcall(function() return ffi.C.HMAC end) and ffi.C
  or ffi.load("/usr/local/openresty/openssl3/lib/libcrypto.so.3")

-- config ------------------------------------------------------------------------------------------

local PG, POOL_SIZE, SECRET, SHA256, DB_PERMITS
local BUFFERED = os.getenv("PG_BUFFERED") ~= "0"   -- read Postgres replies through pgbuf.lua (0: pgmoon's own reads)
local md, md_len = ffi.new("unsigned char[32]"), ffi.new("unsigned int[1]")
local TOKEN_TTL = 30 * 24 * 3600
local IDLE_MS = 600000       -- pooled Postgres connections live through 10 idle minutes

local function parse_database_url(url)
  local user, pass, host, port, db =
    url:match("^postgres[%w]*://([^:@/]*):?([^@/]*)@([^:/]+):?(%d*)/([^?]+)")
  if not user then error("cannot parse DATABASE_URL") end
  return { user = ngx.unescape_uri(user), password = ngx.unescape_uri(pass), host = host,
           port = tonumber(port) or 5432, database = ngx.unescape_uri(db) }
end

local _M = {}
local start_warmup   -- defined with the database helpers below

function _M.init_worker()
  SECRET = os.getenv("JWT_SECRET") or ""
  SHA256 = crypto.EVP_sha256()
  POOL_SIZE = tonumber(os.getenv("DB_POOL_SIZE")) or 10
  PG = parse_database_url(os.getenv("DATABASE_URL") or "")
  -- The keepalive pool only keeps idle connections. The limit itself is a semaphore: nginx's own `backlog`
  -- cap let a worker open 3x pool_size connections when every request checks a connection out and back in.
  PG.pool_size = POOL_SIZE
  DB_PERMITS = require("ngx.semaphore").new(POOL_SIZE)
  start_warmup()
end

-- responses ---------------------------------------------------------------------------------------

local function send(r, status, body)
  r.sent = true
  ngx.status = status
  if body then
    ngx.header.content_length = #body
    ngx.print(body)
  end
end

local function fail(r, status, message)
  send(r, status, '{"errors":{"body":[' .. enc(message) .. ']}}')
end

local function nstr(v)                -- nullable string
  if v == nil then return "null" end
  return enc(v)
end

-- Postgres timestamptz text in UTC ("2025-04-01 12:00:00.123456+00") -> "2025-04-01T12:00:00.123Z"
local function ts(s)
  local frac = s:match("^[^.]*%.(%d+)") or ""
  return s:sub(1, 10) .. "T" .. s:sub(12, 19) .. "." .. (frac .. "000"):sub(1, 3) .. "Z"
end

local function profile_json(username, bio, image, following)
  return '{"username":' .. enc(username) .. ',"bio":' .. nstr(bio) .. ',"image":' .. nstr(image)
      .. ',"following":' .. (following and "true" or "false") .. '}'
end

local function user_json(u, token)
  return '{"user":{"email":' .. enc(u.email) .. ',"token":' .. enc(token) .. ',"username":' .. enc(u.username)
      .. ',"bio":' .. nstr(u.bio) .. ',"image":' .. nstr(u.image) .. '}}'
end

local function article_json(a, with_body)
  local s = '{"slug":' .. enc(a.slug) .. ',"title":' .. enc(a.title) .. ',"description":' .. enc(a.description)
  if with_body then s = s .. ',"body":' .. enc(a.body) end
  return s .. ',"tagList":' .. a.tag_list .. ',"createdAt":"' .. ts(a.created_at) .. '","updatedAt":"'
      .. ts(a.updated_at) .. '","favorited":' .. (a.favorited and "true" or "false")
      .. ',"favoritesCount":' .. a.favorites_count
      .. ',"author":' .. profile_json(a.username, a.bio, a.image, a.following) .. '}'
end

local function comment_json(c)
  return '{"id":' .. c.id .. ',"createdAt":"' .. ts(c.created_at) .. '","updatedAt":"' .. ts(c.updated_at)
      .. '","body":' .. enc(c.body) .. ',"author":' .. profile_json(c.username, c.bio, c.image, c.following) .. '}'
end

-- database ----------------------------------------------------------------------------------------

local UNIQUE = {}   -- sentinel result: the statement hit a unique constraint (SQLSTATE 23505)
local STMT_NAME, SESSION_INIT    -- prepared statement name per SQL text, and a new session's setup (built below)

-- the request's connection, checked out of this worker's pool on first use (waiting for a permit if all
-- POOL_SIZE connections are busy)
local function db(r)
  local pg = r.pg
  if pg then return pg end
  local ok, err = DB_PERMITS:wait(10)
  if not ok then error("waiting for a postgres connection: " .. tostring(err)) end
  r.permit = true
  pg = pgmoon.new(PG)
  if BUFFERED then pg.sock = buffered(pg.sock) end
  ok, err = pg:connect()
  if not ok then
    pcall(pg.sock.close, pg.sock)
    error("postgres connect: " .. tostring(err))
  end
  r.pg = pg
  if pg.sock:getreusedtimes() == 0 then      -- a new session: settings and every prepared statement, one round trip
    local res, qerr = pg:query(SESSION_INIT)
    if not res then error("postgres session setup: " .. tostring(qerr)) end
  end
  return pg
end

-- returns the request's connection to the pool (or closes it after an error) and frees its permit
local function release(r, healthy)
  local pg = r.pg
  if pg then
    r.pg = nil
    if healthy then
      local ok, err = pg:keepalive(IDLE_MS, POOL_SIZE)
      if not ok then ngx.log(ngx.WARN, "postgres keepalive: ", err) end
    else
      pcall(pg.disconnect, pg)
    end
  end
  if r.permit then
    r.permit = false
    DB_PERMITS:post(1)
  end
end

-- Opening a connection costs a SCRAM-SHA-256 handshake: 4096 PBKDF2 rounds on this worker's event loop. So each
-- worker opens its whole pool at startup, in parallel, and keeps idle connections for 10 minutes; otherwise a
-- burst of traffic opens connections on demand and the handshakes stall the very requests that caused them.
function start_warmup()
  ngx.timer.at(0, function(premature)
    if premature then return end
    local threads = {}
    for i = 1, POOL_SIZE do
      threads[i] = ngx.thread.spawn(function()
        local r = { permit = false }
        local ok, err = pcall(db, r)
        if not ok then ngx.log(ngx.WARN, "postgres pool warm-up: ", err) end
        release(r, ok)
      end)
    end
    for i = 1, #threads do ngx.thread.wait(threads[i]) end
  end)
end

-- a parameter as an SQL literal for EXECUTE (standard_conforming_strings is on for every session)
local function literal(v)
  if v == nil then return "NULL" end
  if type(v) == "number" then return string.format("%.0f", v) end   -- every numeric parameter is an integer
  return "'" .. v:gsub("'", "''") .. "'"
end

-- Runs one of the SQL statements below: as `EXECUTE name(literals)` of the session's prepared statement, so
-- Postgres neither parses nor plans it again, or (BEGIN, COMMIT) as plain SQL.
-- Every numeric parameter in the SQL has an explicit cast: through pgmoon's extended protocol (PG_PREPARE=0),
-- Lua numbers arrive as `numeric`, and bigint_column = numeric can't use the column's index.
local function q(r, sql, ...)
  local pg = db(r)
  local name = STMT_NAME[sql]
  local res, err
  if not name then
    res, err = pg:query(sql, ...)
  else
    local n = select("#", ...)
    if n == 0 then
      res, err = pg:query("EXECUTE " .. name)
    else
      local lits = { ... }
      for i = 1, n do lits[i] = literal(lits[i]) end
      res, err = pg:query("EXECUTE " .. name .. "(" .. concat(lits, ",", 1, n) .. ")")
    end
  end
  if res then return res end
  -- pgmoon parses the SQLSTATE but doesn't hand it back, so a unique violation is told by its message
  if err and err:find("duplicate key value violates unique constraint", 1, true) then return UNIQUE end
  error("postgres: " .. tostring(err))
end

-- SQL ---------------------------------------------------------------------------------------------

-- tag_list looks each tag's name up by primary key: the reference's `JOIN tags` makes Postgres hash all 200 tags
-- for every article (-22% per list query, same rows)
local LIST_COLS = [[
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                      FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1::bigint) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::bigint AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id]]
local FULL_COLS = LIST_COLS:gsub("a%.description, ", "a.description, a.body, ", 1)
local ORDER_PAGE = " ORDER BY a.id DESC LIMIT $2::bigint OFFSET $3::bigint"

local SQL = {
  list_all = LIST_COLS .. ORDER_PAGE,
  count_all = "SELECT count(*) AS n FROM (SELECT 1 FROM articles a LIMIT 1000) s",
  list_tag = LIST_COLS .. [[ WHERE a.id IN (SELECT at.article_id FROM article_tags at
      WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4::text)
      ORDER BY at.article_id DESC LIMIT $2::bigint OFFSET $3::bigint) ORDER BY a.id DESC]],
  count_tag = [[SELECT count(*) AS n FROM (SELECT 1 FROM article_tags at
      WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1::text) LIMIT 1000) s]],
  list_author = LIST_COLS .. " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4::text)"
      .. ORDER_PAGE,
  count_author = [[SELECT count(*) AS n FROM (SELECT 1 FROM articles a
      WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1::text) LIMIT 1000) s]],
  list_favorited = LIST_COLS .. [[ WHERE a.id IN (SELECT f.article_id FROM favorites f
      WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4::text)
      ORDER BY f.article_id DESC LIMIT $2::bigint OFFSET $3::bigint) ORDER BY a.id DESC]],
  count_favorited = [[SELECT count(*) AS n FROM (SELECT 1 FROM favorites f
      WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1::text) LIMIT 1000) s]],
  list_feed = LIST_COLS .. [[ WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
      (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
        ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x
      WHERE fo.follower_id = $1::bigint ORDER BY x.id DESC LIMIT $2::bigint OFFSET $3::bigint) ORDER BY a.id DESC]],
  count_feed = [[SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN
      (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1::bigint) LIMIT 1000) s]],

  article_by_slug = FULL_COLS .. " WHERE a.slug = $2::text",
  article_by_id = FULL_COLS .. " WHERE a.id = $2::bigint",
  article_id = "SELECT id FROM articles WHERE slug = $1::text",
  article_owner = "SELECT id, author_id FROM articles WHERE slug = $1::text",
  insert_article = [[INSERT INTO articles (id, slug, author_id, title, description, body)
      SELECT n.id, trim(both '-' from lower(regexp_replace($2::text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
             $1::bigint, $2::text, $3::text, $4::text
        FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
      RETURNING id]],
  -- tagList travels as a JSON array: the same rows as the reference's text[] parameter, without array literals
  insert_tags = [[INSERT INTO tags (name) SELECT DISTINCT value FROM jsonb_array_elements_text($1::jsonb)
      ON CONFLICT (name) DO NOTHING]],
  insert_article_tags = [[INSERT INTO article_tags (article_id, tag_id) SELECT $1::bigint, t.id FROM tags t
      WHERE t.name IN (SELECT value FROM jsonb_array_elements_text($2::jsonb))]],
  update_article = [[UPDATE articles SET title = COALESCE($2::text, title),
      description = COALESCE($3::text, description), body = COALESCE($4::text, body),
      slug = CASE WHEN $2::text IS NULL THEN slug
                  ELSE trim(both '-' from lower(regexp_replace($2::text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
      updated_at = now()
      WHERE id = $1::bigint]],
  delete_article = "DELETE FROM articles WHERE id = $1::bigint",
  favorite = "INSERT INTO favorites (user_id, article_id) VALUES ($1::bigint, $2::bigint) ON CONFLICT DO NOTHING",
  unfavorite = "DELETE FROM favorites WHERE user_id = $1::bigint AND article_id = $2::bigint",

  -- one round trip for the comments page: no row means no such article (404); one row with a NULL comment id
  -- means an article without comments
  comments_by_slug = [[SELECT a.id AS article_id, c.id, c.body, c.created_at, c.updated_at,
      c.username, c.bio, c.image, c.following
      FROM articles a LEFT JOIN LATERAL (
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
          EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::bigint AND fo.followee_id = c.author_id) AS following
          FROM comments c JOIN users u ON u.id = c.author_id
         WHERE c.article_id = a.id
         ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
      WHERE a.slug = $2::text
      ORDER BY c.created_at DESC, c.id DESC]],
  insert_comment = [[WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1::bigint, $2::bigint, $3::text)
      RETURNING id, body, created_at, updated_at, author_id)
      SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id]],
  comment_owner = [[SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
      WHERE c.id = $1::bigint AND a.slug = $2::text]],
  delete_comment = "DELETE FROM comments WHERE id = $1::bigint",

  insert_user = [[INSERT INTO users (username, email, password_hash) VALUES ($1::text, $2::text, $3::text)
      RETURNING id, username, email, bio, image]],
  user_by_email = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1::text",
  user_by_id = "SELECT id, username, email, bio, image FROM users WHERE id = $1::bigint",
  update_user = [[UPDATE users SET email = COALESCE($2::text, email), username = COALESCE($3::text, username),
      password_hash = COALESCE($4::text, password_hash), bio = COALESCE($5::text, bio), image = COALESCE($6::text, image)
      WHERE id = $1::bigint
      RETURNING id, username, email, bio, image]],
  profile = [[SELECT u.id, u.username, u.bio, u.image,
      EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::bigint AND fo.followee_id = u.id) AS following
      FROM users u WHERE u.username = $2::text]],
  user_by_name = "SELECT id, username, bio, image FROM users WHERE username = $1::text",
  follow = "INSERT INTO follows (follower_id, followee_id) VALUES ($1::bigint, $2::bigint) ON CONFLICT DO NOTHING",
  unfollow = "DELETE FROM follows WHERE follower_id = $1::bigint AND followee_id = $2::bigint",
  tags = "SELECT name FROM tags ORDER BY name",
}

-- Each list statement also returns its capped count as a column (an uncorrelated subquery, so Postgres runs it
-- once per query): one round trip per list request instead of two. The count statements stay for a page with
-- no rows (offset past the end, unknown tag or user, no follows), which can't carry the column.
local function with_total(list, count)
  return (list:gsub("^%s*SELECT ", "SELECT (" .. count .. ") AS total, ", 1))
end
SQL.list_all = with_total(SQL.list_all, SQL.count_all)
SQL.list_tag = with_total(SQL.list_tag, (SQL.count_tag:gsub("%$1::text", "$4::text")))
SQL.list_author = with_total(SQL.list_author, (SQL.count_author:gsub("%$1::text", "$4::text")))
SQL.list_favorited = with_total(SQL.list_favorited, (SQL.count_favorited:gsub("%$1::text", "$4::text")))
SQL.list_feed = with_total(SQL.list_feed, SQL.count_feed)

-- Every statement is prepared once per session. plan_cache_mode = force_generic_plan makes Postgres keep one
-- plan per statement instead of re-planning for each set of parameters (its default "auto" mode kept choosing
-- custom plans, which still plans every execution). PG_PREPARE=0 falls back to pgmoon's extended protocol,
-- which parses and plans every query (kept for A/B measurements).
do
  local prepare = os.getenv("PG_PREPARE") ~= "0"
  local mode = os.getenv("PG_PLAN_CACHE_MODE") or "force_generic_plan"
  -- jit = off: a generic plan doesn't know the LIMIT, so the global list's cost estimate passes jit_above_cost
  -- and Postgres JIT-compiles 45 functions on every execution (~100 ms) for a query that reads 10 rows.
  local init = { "SET TimeZone = 'UTC'", "SET standard_conforming_strings = on", "SET jit = off" }
  STMT_NAME = {}
  if prepare then
    insert(init, "SET plan_cache_mode = " .. mode)
    local keys = {}
    for k in pairs(SQL) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      STMT_NAME[SQL[k]] = "s_" .. k
      insert(init, "PREPARE s_" .. k .. " AS " .. SQL[k])
    end
  end
  SESSION_INIT = concat(init, ";\n")
end
_M.SQL = SQL     -- for plan checks

-- input -------------------------------------------------------------------------------------------

local BAD = {}      -- sentinel: a field that is present but invalid

-- digits only (no sign, no spaces), fitting in an int64
local function parse_uint(s)
  if type(s) ~= "string" or s == "" or #s > 19 or s:find("%D") then return nil end
  local n = tonumber(s)
  if n > 9223372036854775807 then return nil end
  return n
end

-- first value of a query parameter: nil if absent, "" for "?k" or "?k="
local function arg(args, k)
  local v = args[k]
  if type(v) == "table" then v = v[1] end
  if v == true then return "" end
  return v
end

-- limit (default 20, 1..100) and offset (default 0, >= 0); a parameter that is present must be valid
local function limit_offset(args)
  local limit, offset = 20, 0
  local v = arg(args, "limit")
  if v ~= nil then
    limit = parse_uint(v)
    if not limit or limit < 1 or limit > 100 then return nil end
  end
  v = arg(args, "offset")
  if v ~= nil then
    offset = parse_uint(v)
    if not offset then return nil end
  end
  return limit, offset
end

local function is_object(v) return type(v) == "table" and getmetatable(v) ~= array_mt end

-- the request body's JSON object under `key`, or nil
local function read_wrapper(key)
  ngx.req.read_body()
  local raw = ngx.req.get_body_data()
  if not raw then return nil end
  local top = safe_decode.decode(raw)
  if not is_object(top) then return nil end
  local inner = top[key]
  if not is_object(inner) then return nil end
  return inner
end

-- absent or null -> nil; a string -> the string; anything else (or "" when non_empty) -> BAD
local function opt_string(m, k, non_empty)
  local v = m[k]
  if v == nil or v == json_null then return nil end
  if type(v) ~= "string" or (non_empty and v == "") then return BAD end
  return v
end

local function req_string(m, k)
  local v = opt_string(m, k, true)
  if v == nil then return BAD end
  return v
end

-- auth --------------------------------------------------------------------------------------------

local function hmac(data)
  crypto.HMAC(SHA256, SECRET, #SECRET, data, #data, md, md_len)
  return ffi.string(md, md_len[0])
end

local JWT_HEADER = b64.encode_base64url('{"alg":"HS256","typ":"JWT"}')

local function sign(id)
  local now = ngx.time()
  local signed = JWT_HEADER .. "." .. b64.encode_base64url(
    '{"sub":"' .. id .. '","iat":' .. now .. ',"exp":' .. (now + TOKEN_TTL) .. '}')
  return signed .. "." .. b64.encode_base64url(hmac(signed))
end

local function b64_json(s)
  local raw = b64.decode_base64url(s)
  return raw and safe_decode.decode(raw)
end

-- user id of a valid token (signature, HS256 only, exp required), or nil. Verified on every request.
local function verify(token)
  local d1 = token:find(".", 1, true)
  local d2 = d1 and token:find(".", d1 + 1, true)
  if not d2 or token:find(".", d2 + 1, true) then return nil end
  local signed = token:sub(1, d2 - 1)
  if b64.encode_base64url(hmac(signed)) ~= token:sub(d2 + 1) then return nil end
  local header = b64_json(token:sub(1, d1 - 1))
  if not is_object(header) or header.alg ~= "HS256" then return nil end
  local claims = b64_json(token:sub(d1 + 1, d2 - 1))
  if not is_object(claims) then return nil end
  local now = ngx.now()
  if type(claims.exp) ~= "number" or now > claims.exp then return nil end
  if claims.nbf ~= nil and (type(claims.nbf) ~= "number" or now < claims.nbf) then return nil end
  if type(claims.sub) ~= "string" then return nil end
  local id = parse_uint(claims.sub)
  if not id or id <= 0 then return nil end
  return id
end

-- viewer (0 if anonymous), the token, and whether an Authorization header was sent at all
local function auth()
  local h = ngx.var.http_authorization
  if not h or h == "" then return 0, nil, false end
  if h:sub(1, 6) ~= "Token " then return 0, nil, true end
  local token = h:sub(7)
  local id = verify(token)
  if not id then return 0, nil, true end
  return id, token, true
end

local function bcrypt(fn, ...)
  local ok, res = ngx.run_worker_thread("bcrypt", "crypt", fn, ...)
  if not ok then error("bcrypt thread: " .. tostring(res)) end
  return res
end

-- handlers: users and profiles --------------------------------------------------------------------

local function register(r)
  local m = read_wrapper("user")
  if not m then return fail(r, 422, "invalid body") end
  local username, email, password = req_string(m, "username"), req_string(m, "email"), req_string(m, "password")
  if username == BAD or email == BAD or password == BAD then
    return fail(r, 422, "username, email and password are required")
  end
  if #password > 72 then return fail(r, 422, "password is too long") end   -- bcrypt's limit
  local hash = bcrypt("hash", password)
  if not hash then error("bcrypt hash failed") end
  local res = q(r, SQL.insert_user, username, email, hash)
  if res == UNIQUE then return fail(r, 422, "username or email is already taken") end
  local u = res[1]
  send(r, 201, user_json(u, sign(u.id)))
end

local function login(r)
  local m = read_wrapper("user")
  if not m then return fail(r, 422, "invalid body") end
  local email, password = req_string(m, "email"), req_string(m, "password")
  if email == BAD or password == BAD then return fail(r, 422, "email and password are required") end
  local u = q(r, SQL.user_by_email, email)[1]
  release(r, true)    -- don't hold a Postgres connection through the ~60 ms bcrypt check
  if not u or #password > 72 or not bcrypt("verify", password, u.password_hash) then
    return fail(r, 401, "invalid email or password")
  end
  send(r, 200, user_json(u, sign(u.id)))
end

local function current_user(r, viewer, token)
  local u = q(r, SQL.user_by_id, viewer)[1]
  if not u then return fail(r, 401, "unauthorized") end
  send(r, 200, user_json(u, token))
end

local function update_user(r, viewer, token)
  local m = read_wrapper("user")
  if not m then return fail(r, 422, "invalid body") end
  local email, username, password = opt_string(m, "email", true), opt_string(m, "username", true),
                                    opt_string(m, "password", true)
  local bio, image = opt_string(m, "bio", false), opt_string(m, "image", false)
  if email == BAD or username == BAD or password == BAD or bio == BAD or image == BAD then
    return fail(r, 422, "invalid user fields")
  end
  local hash
  if password then
    if #password > 72 then return fail(r, 422, "password is too long") end
    hash = bcrypt("hash", password)
    if not hash then error("bcrypt hash failed") end
  end
  local res = q(r, SQL.update_user, viewer, email, username, hash, bio, image)
  if res == UNIQUE then return fail(r, 422, "username or email is already taken") end
  if not res[1] then return fail(r, 401, "unauthorized") end
  send(r, 200, user_json(res[1], token))
end

local function get_profile(r, viewer, _, username)
  local p = q(r, SQL.profile, viewer, username)[1]
  if not p then return fail(r, 404, "profile not found") end
  send(r, 200, '{"profile":' .. profile_json(p.username, p.bio, p.image, p.following) .. '}')
end

local function follow(r, viewer, username, on)
  local p = q(r, SQL.user_by_name, username)[1]
  if not p then return fail(r, 404, "profile not found") end
  q(r, on and SQL.follow or SQL.unfollow, viewer, p.id)
  send(r, 200, '{"profile":' .. profile_json(p.username, p.bio, p.image, on) .. '}')
end

local function tags(r)
  local rows = q(r, SQL.tags)
  local names = {}
  for i = 1, #rows do names[i] = enc(rows[i].name) end
  send(r, 200, '{"tags":[' .. concat(names, ",") .. ']}')
end

-- handlers: articles ------------------------------------------------------------------------------

local function write_list(r, list_sql, count_sql, viewer, limit, offset, filter)
  local rows
  if filter then rows = q(r, list_sql, viewer, limit, offset, filter)
  else rows = q(r, list_sql, viewer, limit, offset) end
  -- the count comes with the rows; only an empty page needs the count statement
  local n
  if rows[1] then n = rows[1].total
  elseif filter then n = q(r, count_sql, filter)[1].n
  elseif count_sql == SQL.count_feed then n = q(r, count_sql, viewer)[1].n
  else n = q(r, count_sql)[1].n end
  local items = {}
  for i = 1, #rows do items[i] = article_json(rows[i], false) end
  send(r, 200, '{"articles":[' .. concat(items, ",") .. '],"articlesCount":' .. n .. '}')
end

local function list_articles(r, viewer)
  local args = ngx.req.get_uri_args(100)
  local limit, offset = limit_offset(args)
  if not limit then return fail(r, 422, "limit must be 1-100 and offset >= 0") end
  -- the first non-empty filter in the order tag, author, favorited applies
  local tag, author, favorited = arg(args, "tag"), arg(args, "author"), arg(args, "favorited")
  if tag and tag ~= "" then
    return write_list(r, SQL.list_tag, SQL.count_tag, viewer, limit, offset, tag)
  elseif author and author ~= "" then
    return write_list(r, SQL.list_author, SQL.count_author, viewer, limit, offset, author)
  elseif favorited and favorited ~= "" then
    return write_list(r, SQL.list_favorited, SQL.count_favorited, viewer, limit, offset, favorited)
  end
  write_list(r, SQL.list_all, SQL.count_all, viewer, limit, offset)
end

local function feed(r, viewer)
  local limit, offset = limit_offset(ngx.req.get_uri_args(100))
  if not limit then return fail(r, 422, "limit must be 1-100 and offset >= 0") end
  write_list(r, SQL.list_feed, SQL.count_feed, viewer, limit, offset)
end

-- ARTICLE_FULL_SELECT by slug or id, written with `status`, or 404
local function write_article(r, status, sql, viewer, key)
  local a = q(r, sql, viewer, key)[1]
  if not a then return fail(r, 404, "article not found") end
  send(r, status, '{"article":' .. article_json(a, true) .. '}')
end

local function get_article(r, viewer, _, slug)
  write_article(r, 200, SQL.article_by_slug, viewer, slug)
end

local function create_article(r, viewer)
  local m = read_wrapper("article")
  if not m then return fail(r, 422, "invalid body") end
  local title, description, body = req_string(m, "title"), req_string(m, "description"), req_string(m, "body")
  if title == BAD or description == BAD or body == BAD then
    return fail(r, 422, "title, description and body are required")
  end
  local tag_json
  local list = m.tagList
  if list ~= nil and list ~= json_null then
    if type(list) ~= "table" or getmetatable(list) ~= array_mt then
      return fail(r, 422, "tagList must be an array of non-empty strings")
    end
    local items = {}
    for i = 1, #list do
      local t = list[i]
      if type(t) ~= "string" or t == "" then return fail(r, 422, "tagList must be an array of non-empty strings") end
      items[i] = enc(t)
    end
    if #items > 0 then tag_json = "[" .. concat(items, ",") .. "]" end
  end

  q(r, "BEGIN")
  local id = q(r, SQL.insert_article, viewer, title, description, body)[1].id
  if tag_json then
    q(r, SQL.insert_tags, tag_json)
    q(r, SQL.insert_article_tags, id, tag_json)
  end
  q(r, "COMMIT")
  write_article(r, 201, SQL.article_by_id, viewer, id)
end

-- the article's id if the viewer wrote it; otherwise responds 404 or 403 and returns nil
local function own_article(r, viewer, slug)
  local a = q(r, SQL.article_owner, slug)[1]
  if not a then fail(r, 404, "article not found"); return nil end
  if a.author_id ~= viewer then fail(r, 403, "not the author"); return nil end
  return a.id
end

local function update_article(r, viewer, _, slug)
  local m = read_wrapper("article")
  if not m then return fail(r, 422, "invalid body") end
  local title, description, body = opt_string(m, "title", true), opt_string(m, "description", true),
                                    opt_string(m, "body", true)
  if title == BAD or description == BAD or body == BAD then
    return fail(r, 422, "title, description and body must be non-empty strings")
  end
  local id = own_article(r, viewer, slug)
  if not id then return end
  q(r, SQL.update_article, id, title, description, body)
  write_article(r, 200, SQL.article_by_id, viewer, id)
end

local function delete_article(r, viewer, _, slug)
  local id = own_article(r, viewer, slug)
  if not id then return end
  q(r, SQL.delete_article, id)
  send(r, 204)
end

-- the article's id by slug; otherwise responds 404 and returns nil
local function article_id(r, slug)
  local a = q(r, SQL.article_id, slug)[1]
  if not a then fail(r, 404, "article not found"); return nil end
  return a.id
end

local function favorite(r, viewer, slug, on)
  local id = article_id(r, slug)
  if not id then return end
  q(r, on and SQL.favorite or SQL.unfavorite, viewer, id)
  write_article(r, 200, SQL.article_by_id, viewer, id)
end

-- handlers: comments ------------------------------------------------------------------------------

local function list_comments(r, viewer, _, slug)
  local rows = q(r, SQL.comments_by_slug, viewer, slug)
  if not rows[1] then return fail(r, 404, "article not found") end
  local items, n = {}, 0
  for i = 1, #rows do
    if rows[i].id then n = n + 1; items[n] = comment_json(rows[i]) end   -- id is NULL: no comments
  end
  send(r, 200, '{"comments":[' .. concat(items, ",") .. ']}')
end

local function create_comment(r, viewer, _, slug)
  local m = read_wrapper("comment")
  if not m then return fail(r, 422, "invalid body") end
  local body = req_string(m, "body")
  if body == BAD then return fail(r, 422, "body is required") end
  local id = article_id(r, slug)
  if not id then return end
  local c = q(r, SQL.insert_comment, id, viewer, body)[1]
  c.following = false
  send(r, 201, '{"comment":' .. comment_json(c) .. '}')
end

local function delete_comment(r, viewer, _, slug, raw_id)
  local id = parse_uint(raw_id)
  if not id then return fail(r, 404, "comment not found") end
  local c = q(r, SQL.comment_owner, id, slug)[1]
  if not c then return fail(r, 404, "comment not found") end
  if c.author_id ~= viewer then return fail(r, 403, "not the author") end
  q(r, SQL.delete_comment, id)
  send(r, 204)
end

-- routing -----------------------------------------------------------------------------------------

-- auth required: a missing or invalid token gives 401
local function required(r, handler, ...)
  local viewer, token = auth()
  if viewer == 0 then return fail(r, 401, "unauthorized") end
  return handler(r, viewer, token, ...)
end

-- auth optional: no header means viewer 0; a header that is present but invalid gives 401
local function optional(r, handler, ...)
  local viewer, token, present = auth()
  if present and viewer == 0 then return fail(r, 401, "unauthorized") end
  return handler(r, viewer, token, ...)
end

-- adapters for handlers that take the path value(s) plus a flag
local function follow_on(r, viewer, _, u) return follow(r, viewer, u, true) end
local function follow_off(r, viewer, _, u) return follow(r, viewer, u, false) end
local function favorite_on(r, viewer, _, s) return favorite(r, viewer, s, true) end
local function favorite_off(r, viewer, _, s) return favorite(r, viewer, s, false) end

local function route(r)
  local method = ngx.req.get_method()
  local path = ngx.var.request_uri:match("^[^?]*")
  local seg, n = {}, 0
  for s in path:gmatch("/([^/]*)") do
    n = n + 1
    seg[n] = ngx.unescape_uri(s)
  end
  if seg[1] ~= "api" then return fail(r, 404, "not found") end
  local s2, s3 = seg[2], seg[3]

  if s2 == "articles" then
    if n == 2 then
      if method == "GET" then return optional(r, list_articles) end
      if method == "POST" then return required(r, create_article) end
    elseif s3 ~= "" then
      if n == 3 then
        if method == "GET" then
          if s3 == "feed" then return required(r, feed) end
          return optional(r, get_article, s3)
        end
        if method == "PUT" then return required(r, update_article, s3) end
        if method == "DELETE" then return required(r, delete_article, s3) end
      elseif n == 4 and seg[4] == "favorite" then
        if method == "POST" then return required(r, favorite_on, s3) end
        if method == "DELETE" then return required(r, favorite_off, s3) end
      elseif n == 4 and seg[4] == "comments" then
        if method == "GET" then return optional(r, list_comments, s3) end
        if method == "POST" then return required(r, create_comment, s3) end
      elseif n == 5 and seg[4] == "comments" and seg[5] ~= "" and method == "DELETE" then
        return required(r, delete_comment, s3, seg[5])
      end
    end
  elseif s2 == "tags" then
    if n == 2 and method == "GET" then return tags(r) end
  elseif s2 == "profiles" then
    if n >= 3 and s3 ~= "" then
      if n == 3 and method == "GET" then return optional(r, get_profile, s3) end
      if n == 4 and seg[4] == "follow" then
        if method == "POST" then return required(r, follow_on, s3) end
        if method == "DELETE" then return required(r, follow_off, s3) end
      end
    end
  elseif s2 == "user" then
    if n == 2 then
      if method == "GET" then return required(r, current_user) end
      if method == "PUT" then return required(r, update_user) end
    end
  elseif s2 == "users" then
    if n == 2 and method == "POST" then return register(r) end
    if n == 3 and s3 == "login" and method == "POST" then return login(r) end
  end
  fail(r, 404, "not found")
end

function _M.handle()
  local r = { sent = false, permit = false }
  local ok, err = xpcall(route, debug.traceback, r)
  release(r, ok)
  if not ok then
    ngx.log(ngx.ERR, err)
    if not r.sent then fail(r, 500, "internal error") end
  end
end

return _M
