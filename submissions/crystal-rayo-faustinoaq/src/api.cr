require "rayo"
require "./sql"

module Conduit
  KEY = Rayo::JWT::Key.new(ENV["JWT_SECRET"])
  alias Context = Rayo::Context
  alias Row = Rayo::PG::Row

  class Invalid < Exception
    getter code : Int32

    def initialize(@code = 422)
      super("invalid request")
    end
  end

  # Retained per connection context; no request data survives reset.
  class State
    getter scratch = Rayo::Buf.new(1024)
    getter tags = Rayo::PG::Batch.new
    getter array_scratch = Rayo::Buf.new(1024)
    getter token = Bytes.new(4096)
    getter claims = Bytes.new(4096)
    getter payload = Rayo::Buf.new(128)
    property viewer = 0_i64
    property fresh = false
  end

  STATES = {} of UInt64 => State

  def self.state(ctx)
    STATES[ctx.object_id] ||= State.new
  end

  def self.error(ctx, code)
    ctx.output.clear
    ctx.status code
    ctx.json errors: {body: {"request failed"}}
  end

  def self.handle(ctx, &)
    state(ctx).scratch.clear
    state(ctx).scratch.reserve(ctx.body.size * 3 + ctx.path.size * 3 + ctx.query.size * 3 + 1)
    state(ctx).fresh = false
    yield
  rescue ex : Invalid
    error(ctx, ex.code)
  rescue ex : Rayo::JSON::Error
    error(ctx, 422)
  end

  def self.uint(bytes : Bytes) : Int64?
    return nil if bytes.empty?
    n = 0_i64
    bytes.each do |c|
      return nil unless 48 <= c <= 57
      return nil if n > (Int64::MAX - (c - 48)) // 10
      n = n * 10 + c - 48
    end
    n
  end

  def self.auth(ctx, required = true)
    h = ctx.header("Authorization")
    if h.empty?
      raise Invalid.new(401) if required
      return state(ctx).viewer = 0_i64
    end
    raise Invalid.new(401) unless h.size > 6 && h[0, 6] == "Token ".to_slice
    claims = KEY.verify(h[6..], state(ctx).claims, now: Time.utc.to_unix)
    raise Invalid.new(401) unless claims
    begin
      raise Invalid.new(401) unless claims["exp"].i64?
      id = uint(claims["sub"].string)
      raise Invalid.new(401) unless id && id > 0
      state(ctx).viewer = id
    rescue Rayo::JSON::Error
      raise Invalid.new(401)
    end
  end

  def self.token(ctx)
    h = ctx.header("Authorization")
    h.size > 6 ? h[6..] : Bytes.empty
  end

  def self.issue(ctx, id)
    s = state(ctx)
    s.payload.clear
    s.payload << "{\"sub\":\"" << id << "\",\"iat\":" << Time.utc.to_unix << ",\"exp\":" << (Time.utc.to_unix + 30 * 86400) << "}"
    KEY.sign(Bytes.new(s.payload.ptr, s.payload.len), s.token)
  end

  def self.wrapper(ctx, name)
    m = ctx.json_body[name]
    raise Invalid.new unless m.object?
    m
  end

  def self.field(ctx, m, key, required = false, nonempty = true) : Bytes?
    found = nil.as(Rayo::JSON::Reader?)
    m.object do |k, v|
      if k.string_equals?(key)
        raise Invalid.new if found
        found = v
      end
    end
    unless v = found
      raise Invalid.new if required
      return nil
    end
    if v.null?
      raise Invalid.new if required
      return nil
    end
    raise Invalid.new unless v.string?
    b = state(ctx).scratch
    # Leave old spans intact if growing the arena would move them: reserve the
    # complete body once at entry, before exposing any decoded field.
    value = v.string(Bytes.new(b.tail, b.cap - b.len))
    b.len += value.size
    raise Invalid.new if nonempty && value.empty?
    value
  end

  def self.body(ctx, name)
    state(ctx).scratch.reserve(ctx.body.size + 1)
    wrapper(ctx, name)
  end

  def self.decode(ctx, bytes)
    b = state(ctx).scratch
    p = b.reserve(bytes.size)
    n = 0
    i = 0
    while i < bytes.size
      c = bytes[i]
      if c == 37 && i + 2 < bytes.size
        x = hex(bytes[i + 1]); y = hex(bytes[i + 2])
        raise Invalid.new if x < 0 || y < 0
        p[n] = (x * 16 + y).to_u8
        i += 3
      else
        p[n] = c == 43 ? 32_u8 : c
        i += 1
      end
      n += 1
    end
    b.len += n
    Bytes.new(p, n)
  end

  def self.hex(c)
    return c.to_i - 48 if 48 <= c <= 57
    return (c | 32).to_i - 87 if 97 <= (c | 32) <= 102
    -1
  end

  def self.query_present?(ctx, name)
    q = ctx.query
    offset = 0
    while offset < q.size
      stop = offset
      while stop < q.size && q[stop] != 38
        stop += 1
      end
      eq = offset
      while eq < stop && q[eq] != 61
        eq += 1
      end
      return true if q[offset, eq - offset] == name.to_slice
      offset = stop + 1
    end
    false
  end

  def self.page(ctx)
    l = ctx.query("limit"); o = ctx.query("offset")
    limit = query_present?(ctx, "limit") ? uint(l) : 20_i64
    offset = query_present?(ctx, "offset") ? uint(o) : 0_i64
    raise Invalid.new unless limit && 1 <= limit <= 100 && offset
    {limit, offset}
  end

  def self.nullable(row, col)
    row.null?(col) ? nil : row.str(col)
  end

  def self.profile(row, col, following)
    {username: row.str(col), bio: nullable(row, col + 1), image: nullable(row, col + 2), following: following}
  end

  def self.user(ctx, res)
    return error(ctx, res.sqlstate == "23505".to_slice ? 422 : 500) if res.error?
    return error(ctx, 401) unless row = res.first?
    tok = state(ctx).fresh ? issue(ctx, row.i64(0)) : token(ctx)
    ctx.json user: {email: row.str(2), token: tok, username: row.str(1), bio: nullable(row, 3), image: nullable(row, 4)}
  end

  # Conduit requires millisecond precision; Rayo timestamps emit microseconds.
  def self.timestamp(ctx, bytes)
    b = state(ctx).scratch
    p = b.reserve(24)
    p.copy_from(bytes.to_unsafe, 19)
    p[10] = 84; p[19] = 46; p[20] = 48; p[21] = 48; p[22] = 48; p[23] = 90
    if bytes.size > 20 && bytes[19] == 46
      i = 20
      while i < 23 && i < bytes.size && 48 <= bytes[i] <= 57
        p[i] = bytes[i]; i += 1
      end
    end
    b.len += 24
    Bytes.new(p, 24)
  end

  struct TagList
    def initialize(@row : Row, @col : Int32, @scratch : Rayo::Buf)
    end

    def to_json(j : Rayo::JSON::Writer)
      @scratch.reserve(@row.str(@col).size)
      j.array do
        @row.each_array(@col, Bytes.new(@scratch.ptr, @scratch.cap)) { |tag| j.value(tag) }
      end
    end
  end

  def self.article_fields(ctx, row, full, favorited = row.bool(8 + (full ? 1 : 0)), following = row.bool(12 + (full ? 1 : 0)), include_body = full)
    s = state(ctx)
    s.scratch.clear
    s.scratch.reserve(48)
    n = full ? 1 : 0
    fields = {slug: row.str(1), title: row.str(2), description: row.str(3),
              createdAt: timestamp(ctx, row.str(4 + n)), updatedAt: timestamp(ctx, row.str(5 + n)),
              tagList: TagList.new(row, 6 + n, s.array_scratch), favoritesCount: row.i64(7 + n), favorited: favorited,
              author: profile(row, 9 + n, following)}
    include_body ? fields.merge({body: row.str(4)}) : fields
  end

  def self.article(ctx, res)
    return error(ctx, 500) if res.error?
    if row = res.first?
      ctx.json article: article_fields(ctx, row, true)
    else
      error(ctx, 404)
    end
  end

  def self.fetch_article(ctx, id : Int64)
    ctx.db.query(Sql::ARTICLE_BY_ID, state(ctx).viewer, id) { |res, ctx| Conduit.article(ctx, res) }
  end

  def self.fetch_slug(ctx)
    ctx.db.query(Sql::ARTICLE_BY_SLUG, state(ctx).viewer, decode(ctx, ctx.param("slug"))) { |res, ctx| Conduit.article(ctx, res) }
  end

  def self.comment(ctx, row, following, col = 0)
    state(ctx).scratch.clear
    state(ctx).scratch.reserve(48)
    {id: row.i64(col), body: row.str(col + 1), createdAt: timestamp(ctx, row.str(col + 2)), updatedAt: timestamp(ctx, row.str(col + 3)), author: profile(row, col + 4, following)}
  end

  def self.deleted(ctx, res)
    return if res.error?
    if row = res.first?
      if row.i64(0) == state(ctx).viewer
        ctx.status 204
      else
        error(ctx, 403)
      end
    else
      error(ctx, 404)
    end
  end
end

module Conduit
  CREATE = Rayo::PG::Statement.new(<<-SQL)
    WITH a AS (
      INSERT INTO articles (id, slug, author_id, title, description, body)
      SELECT n.id, #{Sql::SLUGIFY} || '-' || n.id, $1, $2, $3, $4
      FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id
    ), t AS (
      INSERT INTO tags (name) SELECT DISTINCT unnest($5::text[]) ORDER BY 1
      ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id
    ), links AS (
      INSERT INTO article_tags (article_id, tag_id) SELECT a.id, t.id FROM a CROSS JOIN t
    ) SELECT id FROM a
    SQL

  def self.register(ctx, hash)
    state(ctx).scratch.clear
    m = body(ctx, "user")
    name = field(ctx, m, "username", true).not_nil!
    email = field(ctx, m, "email", true).not_nil!
    state(ctx).fresh = true
    ctx.status 201
    ctx.db.query(Sql::REGISTER, name, email, hash) { |res, ctx| Conduit.user(ctx, res) }
  end

  def self.update_user(ctx, hash : Bytes? = nil)
    state(ctx).scratch.clear
    m = body(ctx, "user")
    email = field(ctx, m, "email")
    name = field(ctx, m, "username")
    bio = field(ctx, m, "bio", nonempty: false)
    image = field(ctx, m, "image", nonempty: false)
    ctx.db.query(Sql::UPDATE_USER, state(ctx).viewer, email, name, hash, bio, image) { |res, ctx| Conduit.user(ctx, res) }
  end
end
