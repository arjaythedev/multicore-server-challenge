require "kemal"
require "pg"
require "jwt"
require "crypto/bcrypt/password"

# Conduit on Kemal + crystal-pg, written the way a Kemal app normally is: routes, a DB pool,
# JSON::Builder, the reference SQL. start.sh runs one of these processes per core,
# all listening directly on the same port with SO_REUSEPORT.

SECRET      = ENV["JWT_SECRET"]
BCRYPT_COST = 10

# max_connections is 100 and every process shares the 95 we may use.
WORKERS = ENV.fetch("WORKERS", System.cpu_count.to_s).to_i
POOL    = {95 // {WORKERS, 1}.max, 1}.max

DBC = DB.open(URI.parse(ENV["DATABASE_URL"]).tap { |u|
  u.query = "initial_pool_size=1&max_idle_pool_size=#{POOL}&max_pool_size=#{POOL}&retry_attempts=1&checkout_timeout=10"
}.to_s)

# ---- reference SQL (SPEC.md) ----

ARTICLE_COLS = <<-SQL
  a.created_at, a.updated_at,
         ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
         u.username, u.bio, u.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
    FROM articles a
    JOIN users u ON u.id = a.author_id
  SQL
ARTICLE_LIST_SELECT = "SELECT a.id, a.slug, a.title, a.description, " + ARTICLE_COLS
ARTICLE_FULL_SELECT = "SELECT a.id, a.slug, a.title, a.description, a.body, " + ARTICLE_COLS
ORDER_PAGE          = " ORDER BY a.id DESC LIMIT $2 OFFSET $3"
SLUGIFY             = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))"

LISTS = {
  "none" => {
    ARTICLE_LIST_SELECT + ORDER_PAGE,
    "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s",
  },
  "tag" => {
    ARTICLE_LIST_SELECT + " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
    "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
  },
  "author" => {
    ARTICLE_LIST_SELECT + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)" + ORDER_PAGE,
    "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
  },
  "favorited" => {
    ARTICLE_LIST_SELECT + " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
    "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
  },
}
FEED_PAGE = ARTICLE_LIST_SELECT + " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL " \
                                  "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x " \
                                  "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
FEED_COUNT = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"

USER_COLS = "id, username, email, bio, image"

# ---- errors, formats ----

class ApiError < Exception
  getter status : Int32

  def initialize(@status, message)
    super(message)
  end
end

def fail(status, message) : NoReturn
  raise ApiError.new(status, message)
end

def unique_violation?(e) : Bool
  e.is_a?(PQ::PQError) && e.fields.any? { |f| f.name == :code && f.message == "23505" }
end

# RFC 3339 UTC, exactly 3 fractional digits, truncated (%L truncates).
def ts(t : Time) : String
  t.to_utc.to_s("%Y-%m-%dT%H:%M:%S.%LZ")
end

def json(env, status : Int32, body : String) : String
  env.response.status_code = status
  env.response.content_type = "application/json"
  body
end

def error_body(message : String) : String
  {errors: {body: [message]}}.to_json
end

def handle(env, &)
  yield
rescue e : ApiError
  json(env, e.status, error_body(e.message.not_nil!))
rescue e
  STDERR.puts "error: #{e.message}"
  json(env, 500, error_body("internal error"))
end

record Profile, username : String, bio : String?, image : String?, following : Bool do
  def to_json(json : JSON::Builder)
    json.object do
      json.field "username", username
      json.field "bio", bio
      json.field "image", image
      json.field "following", following
    end
  end
end

record Article, id : Int64, slug : String, title : String, description : String, body : String?,
  created_at : Time, updated_at : Time, tags : Array(String), favorites_count : Int64,
  favorited : Bool, author : Profile do
  def to_json(json : JSON::Builder)
    json.object do
      json.field "slug", slug
      json.field "title", title
      json.field "description", description
      json.field "body", body if body
      json.field "tagList", tags
      json.field "createdAt", ts(created_at)
      json.field "updatedAt", ts(updated_at)
      json.field "favorited", favorited
      json.field "favoritesCount", favorites_count
      json.field "author", author
    end
  end
end

def read_article(rs : DB::ResultSet, full : Bool) : Article
  id = rs.read(Int64)
  slug = rs.read(String)
  title = rs.read(String)
  description = rs.read(String)
  body = full ? rs.read(String) : nil
  Article.new(id, slug, title, description, body, rs.read(Time), rs.read(Time), rs.read(Array(String)),
    rs.read(Int64), rs.read(Bool), Profile.new(rs.read(String), rs.read(String?), rs.read(String?), rs.read(Bool)))
end

def article_by(db, where : String, viewer : Int64, arg) : Article?
  db.query_one?(ARTICLE_FULL_SELECT + where, viewer, arg) { |rs| read_article(rs, true) }
end

def user_json(rs : DB::ResultSet, token : String) : String
  rs.read(Int64)
  username, email, bio, image = rs.read(String), rs.read(String), rs.read(String?), rs.read(String?)
  {user: {email: email, token: token, username: username, bio: bio, image: image}}.to_json
end

# ---- auth ----

def issue_token(uid : Int64) : String
  now = Time.utc.to_unix
  JWT.encode({"sub" => uid.to_s, "iat" => now, "exp" => now + 30 * 86400}, SECRET, JWT::Algorithm::HS256)
end

# {viewer, token}; viewer 0 when there is no header and auth is optional.
def auth(env, required : Bool) : {Int64, String}
  header = env.request.headers["Authorization"]?
  unless header
    fail(401, "missing token") if required
    return {0_i64, ""}
  end
  fail(401, "invalid token") unless header.starts_with?("Token ")
  token = header[6..].strip
  payload = begin
    JWT.decode(token, SECRET, JWT::Algorithm::HS256)[0]
  rescue
    fail(401, "invalid token")
  end
  fail(401, "invalid token") unless payload["exp"]?.try(&.as_i64?)
  sub = payload["sub"]?.try(&.as_s?)
  uid = sub.to_i64? if sub && !sub.empty? && sub.each_char.all?(&.ascii_number?)
  fail(401, "invalid token") unless uid && uid > 0
  {uid, token}
end

# ---- request bodies ----

# The object under `key`, or 422.
def wrapper(env, key : String) : Hash(String, JSON::Any)
  raw = env.request.body.try(&.gets_to_end) || ""
  top = JSON.parse(raw).as_h? rescue nil
  inner = top.try(&.[key]?).try(&.as_h?)
  fail(422, "invalid body") unless inner
  inner
end

def req_string(m, k : String) : String
  s = m[k]?.try(&.as_s?)
  fail(422, "#{k} can't be blank") if s.nil? || s.empty?
  s
end

# Absent or null: nil. Otherwise a string (non-empty when asked), or 422.
def opt_string(m, k : String, non_empty : Bool) : String?
  v = m[k]?
  return nil if v.nil? || v.raw.nil?
  s = v.as_s?
  fail(422, "invalid #{k}") if s.nil? || (non_empty && s.empty?)
  s
end

def hash_password(pw : String) : String
  fail(422, "password is too long") if pw.bytesize > 72
  Crypto::Bcrypt::Password.create(pw, cost: BCRYPT_COST).to_s
end

def uint_param(s : String) : Int64?
  return nil if s.empty? || !s.each_char.all?(&.ascii_number?)
  s.to_i64?
end

def limit_offset(env) : {Int64, Int64}
  q = env.params.query
  limit = 20_i64
  offset = 0_i64
  if v = q["limit"]?
    n = uint_param(v)
    fail(422, "invalid limit") unless n && 1 <= n <= 100
    limit = n
  end
  if v = q["offset"]?
    n = uint_param(v)
    fail(422, "invalid offset") unless n
    offset = n
  end
  {limit, offset}
end

def list_json(env, articles : Array(Article), count : Int64) : String
  json(env, 200, {articles: articles, articlesCount: count}.to_json)
end

# ---- routes ----

Kemal.config.logging = false
Kemal.config.powered_by_header = false
Kemal.config.env = "production"

post "/api/users" do |env|
  handle(env) do
    m = wrapper(env, "user")
    username, email, password = req_string(m, "username"), req_string(m, "email"), req_string(m, "password")
    hash = hash_password(password)
    begin
      DBC.query_one("INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING #{USER_COLS}",
        username, email, hash) { |rs|
        id = rs.read(Int64)
        name, mail, bio, image = rs.read(String), rs.read(String), rs.read(String?), rs.read(String?)
        json(env, 201, {user: {email: mail, token: issue_token(id), username: name, bio: bio, image: image}}.to_json)
      }
    rescue e
      fail(422, "username or email is already taken") if unique_violation?(e)
      raise e
    end
  end
end

post "/api/users/login" do |env|
  handle(env) do
    m = wrapper(env, "user")
    email, password = req_string(m, "email"), req_string(m, "password")
    row = DBC.query_one?("SELECT #{USER_COLS}, password_hash FROM users WHERE email = $1", email,
      as: {Int64, String, String, String?, String?, String})
    fail(401, "invalid email or password") unless row
    id, username, mail, bio, image, hash = row
    ok = Crypto::Bcrypt::Password.new(hash).verify(password) rescue false
    fail(401, "invalid email or password") unless ok
    json(env, 200, {user: {email: mail, token: issue_token(id), username: username, bio: bio, image: image}}.to_json)
  end
end

get "/api/user" do |env|
  handle(env) do
    viewer, token = auth(env, true)
    body = DBC.query_one?("SELECT #{USER_COLS} FROM users WHERE id = $1", viewer) { |rs| user_json(rs, token) }
    fail(401, "unauthorized") unless body
    json(env, 200, body)
  end
end

put "/api/user" do |env|
  handle(env) do
    viewer, token = auth(env, true)
    m = wrapper(env, "user")
    email, username, password = opt_string(m, "email", true), opt_string(m, "username", true), opt_string(m, "password", true)
    bio, image = opt_string(m, "bio", false), opt_string(m, "image", false)
    hash = password ? hash_password(password) : nil
    body = begin
      DBC.query_one?(<<-SQL, viewer, email, username, hash, bio, image) { |rs| user_json(rs, token) }
        UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                         password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
         WHERE id = $1
        RETURNING #{USER_COLS}
        SQL
    rescue e
      fail(422, "username or email is already taken") if unique_violation?(e)
      raise e
    end
    fail(401, "unauthorized") unless body
    json(env, 200, body)
  end
end

get "/api/profiles/:username" do |env|
  handle(env) do
    viewer, _ = auth(env, false)
    p = DBC.query_one?(<<-SQL, viewer, env.params.url["username"]) { |rs| rs.read(Int64); Profile.new(rs.read(String), rs.read(String?), rs.read(String?), rs.read(Bool)) }
      SELECT u.id, u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
        FROM users u WHERE u.username = $2
      SQL
    fail(404, "profile not found") unless p
    json(env, 200, {profile: p}.to_json)
  end
end

{"POST" => true, "DELETE" => false}.each do |method, follow|
  Kemal::RouteHandler::INSTANCE.add_route(method, "/api/profiles/:username/follow") do |env|
    handle(env) do
      viewer, _ = auth(env, true)
      row = DBC.query_one?("SELECT id, username, bio, image FROM users WHERE username = $1", env.params.url["username"],
        as: {Int64, String, String?, String?})
      fail(404, "profile not found") unless row
      id, username, bio, image = row
      if follow
        DBC.exec("INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", viewer, id)
      else
        DBC.exec("DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2", viewer, id)
      end
      json(env, 200, {profile: Profile.new(username, bio, image, follow)}.to_json)
    end
  end
end

get "/api/articles" do |env|
  handle(env) do
    viewer, _ = auth(env, false)
    limit, offset = limit_offset(env)
    q = env.params.query
    # only the first non-empty filter, in this order, applies
    kind = {"tag", "author", "favorited"}.find { |k| q[k]?.presence } || "none"
    value = q[kind]?
    page_sql, count_sql = LISTS[kind]
    articles = [] of Article
    if value
      DBC.query(page_sql, viewer, limit, offset, value) { |rs| rs.each { articles << read_article(rs, false) } }
      count = DBC.scalar(count_sql, value).as(Int64)
    else
      DBC.query(page_sql, viewer, limit, offset) { |rs| rs.each { articles << read_article(rs, false) } }
      count = DBC.scalar(count_sql).as(Int64)
    end
    list_json(env, articles, count)
  end
end

get "/api/articles/feed" do |env|
  handle(env) do
    viewer, _ = auth(env, true)
    limit, offset = limit_offset(env)
    articles = [] of Article
    DBC.query(FEED_PAGE, viewer, limit, offset) { |rs| rs.each { articles << read_article(rs, false) } }
    list_json(env, articles, DBC.scalar(FEED_COUNT, viewer).as(Int64))
  end
end

get "/api/articles/:slug" do |env|
  handle(env) do
    viewer, _ = auth(env, false)
    a = article_by(DBC, " WHERE a.slug = $2", viewer, env.params.url["slug"])
    fail(404, "article not found") unless a
    json(env, 200, {article: a}.to_json)
  end
end

post "/api/articles" do |env|
  handle(env) do
    viewer, _ = auth(env, true)
    m = wrapper(env, "article")
    title, description, body = req_string(m, "title"), req_string(m, "description"), req_string(m, "body")
    tags = [] of String
    if (tl = m["tagList"]?) && !tl.raw.nil?
      arr = tl.as_a?
      fail(422, "invalid tagList") unless arr
      arr.each do |t|
        s = t.as_s?
        fail(422, "invalid tagList") if s.nil? || s.empty?
        tags << s
      end
    end
    id = 0_i64
    DBC.transaction do |tx|
      c = tx.connection
      id = c.query_one(<<-SQL, viewer, title, description, body, as: Int64)
        INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, #{SLUGIFY} || '-' || n.id, $1, $2, $3, $4
          FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
        RETURNING id
        SQL
      unless tags.empty?
        c.exec("INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING", tags)
        c.exec("INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])", id, tags)
      end
    end
    a = article_by(DBC, " WHERE a.id = $2", viewer, id)
    fail(404, "article not found") unless a
    json(env, 201, {article: a}.to_json)
  end
end

# {id, author_id} of the article, or 404.
def article_owner(slug : String) : {Int64, Int64}
  row = DBC.query_one?("SELECT id, author_id FROM articles WHERE slug = $1", slug, as: {Int64, Int64})
  fail(404, "article not found") unless row
  row
end

put "/api/articles/:slug" do |env|
  handle(env) do
    viewer, _ = auth(env, true)
    m = wrapper(env, "article")
    title, description, body = opt_string(m, "title", true), opt_string(m, "description", true), opt_string(m, "body", true)
    id, author = article_owner(env.params.url["slug"])
    fail(403, "not the author") unless author == viewer
    DBC.exec(<<-SQL, id, title, description, body)
      UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
             slug = CASE WHEN $2::text IS NULL THEN slug ELSE #{SLUGIFY} || '-' || id END,
             updated_at = now()
       WHERE id = $1
      SQL
    a = article_by(DBC, " WHERE a.id = $2", viewer, id)
    fail(404, "article not found") unless a
    json(env, 200, {article: a}.to_json)
  end
end

delete "/api/articles/:slug" do |env|
  handle(env) do
    viewer, _ = auth(env, true)
    id, author = article_owner(env.params.url["slug"])
    fail(403, "not the author") unless author == viewer
    DBC.exec("DELETE FROM articles WHERE id = $1", id)
    env.response.status_code = 204
    ""
  end
end

{"POST" => true, "DELETE" => false}.each do |method, fav|
  Kemal::RouteHandler::INSTANCE.add_route(method, "/api/articles/:slug/favorite") do |env|
    handle(env) do
      viewer, _ = auth(env, true)
      id = DBC.query_one?("SELECT id FROM articles WHERE slug = $1", env.params.url["slug"], as: Int64)
      fail(404, "article not found") unless id
      if fav
        DBC.exec("INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", viewer, id)
      else
        DBC.exec("DELETE FROM favorites WHERE user_id = $1 AND article_id = $2", viewer, id)
      end
      a = article_by(DBC, " WHERE a.id = $2", viewer, id)
      fail(404, "article not found") unless a
      json(env, 200, {article: a}.to_json)
    end
  end
end

def comment_json(json : JSON::Builder, rs : DB::ResultSet, following : Bool?) : Nil
  json.object do
    json.field "id", rs.read(Int64)
    json.field "body", rs.read(String)
    json.field "createdAt", ts(rs.read(Time))
    json.field "updatedAt", ts(rs.read(Time))
    username, bio, image = rs.read(String), rs.read(String?), rs.read(String?)
    json.field "author", Profile.new(username, bio, image, following.nil? ? rs.read(Bool) : following)
  end
end

def comments_json(rs : DB::ResultSet) : String
  JSON.build do |json|
    json.object do
      json.field "comments" do
        json.array { rs.each { comment_json(json, rs, nil) } }
      end
    end
  end
end

def new_comment_json(rs : DB::ResultSet) : String
  JSON.build do |json|
    json.object { json.field("comment") { comment_json(json, rs, false) } }
  end
end

get "/api/articles/:slug/comments" do |env|
  handle(env) do
    viewer, _ = auth(env, false)
    id = DBC.query_one?("SELECT id FROM articles WHERE slug = $1", env.params.url["slug"], as: Int64)
    fail(404, "article not found") unless id
    rs = DBC.query(<<-SQL, viewer, id)
      SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
        FROM comments c JOIN users u ON u.id = c.author_id
       WHERE c.article_id = $2
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT 100
      SQL
    body = begin
      comments_json(rs)
    ensure
      rs.close
    end
    json(env, 200, body)
  end
end

post "/api/articles/:slug/comments" do |env|
  handle(env) do
    viewer, _ = auth(env, true)
    m = wrapper(env, "comment")
    text = req_string(m, "body")
    id = DBC.query_one?("SELECT id FROM articles WHERE slug = $1", env.params.url["slug"], as: Int64)
    fail(404, "article not found") unless id
    rs = DBC.query(<<-SQL, id, viewer, text)
      WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
                 RETURNING id, body, created_at, updated_at, author_id)
      SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
        FROM c JOIN users u ON u.id = c.author_id
      SQL
    body = begin
      fail(500, "comment not created") unless rs.move_next
      new_comment_json(rs)
    ensure
      rs.close
    end
    json(env, 201, body)
  end
end

delete "/api/articles/:slug/comments/:id" do |env|
  handle(env) do
    viewer, _ = auth(env, true)
    cid = uint_param(env.params.url["id"])
    fail(404, "comment not found") unless cid
    author = DBC.query_one?("SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
      cid, env.params.url["slug"], as: Int64)
    fail(404, "comment not found") unless author
    fail(403, "not the author") unless author == viewer
    DBC.exec("DELETE FROM comments WHERE id = $1", cid)
    env.response.status_code = 204
    ""
  end
end

get "/api/tags" do |env|
  handle(env) do
    tags = [] of String
    DBC.query("SELECT name FROM tags ORDER BY name") { |rs| rs.each { tags << rs.read(String) } }
    json(env, 200, {tags: tags}.to_json)
  end
end

error 404 do |env|
  env.response.content_type = "application/json"
  error_body("not found")
end

Kemal.run do |config|
  config.server.not_nil!.bind_tcp(ENV.fetch("HOST", "127.0.0.1"), ENV.fetch("PORT", "3000").to_i, reuse_port: true)
end
