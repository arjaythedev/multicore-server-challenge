require "./api"
require "./passwords"
require "./reads"

app = Rayo::App.new
app.gzip = ENV["GZIP"]? != "0"
app.on_worker_start do |_index|
  Passwords.start
  Conduit::Reads.start
end

app.get("/api/tags") { |ctx| Conduit::Reads.enqueue(ctx, 7, 0_i64) }

app.post "/api/users" do |ctx|
  Conduit.handle(ctx) do
    m = Conduit.body(ctx, "user")
    Conduit.field(ctx, m, "username", true)
    Conduit.field(ctx, m, "email", true)
    pw = Conduit.field(ctx, m, "password", true).not_nil!
    Passwords.acquire(ctx, pw, 0)
  end
end

app.post "/api/users/login" do |ctx|
  Conduit.handle(ctx) do
    m = Conduit.body(ctx, "user")
    email = Conduit.field(ctx, m, "email", true).not_nil!
    Conduit.field(ctx, m, "password", true)
    ctx.db.query(Sql::LOGIN, email) do |res, ctx|
      unless res.error?
        if row = res.first?
          # The body stays pinned while the external password job runs.
          Conduit.state(ctx).scratch.clear
          pw = Conduit.field(ctx, Conduit.body(ctx, "user"), "password", true).not_nil!
          Passwords.acquire(ctx, pw, 1, row.str(5), row.i64(0))
        else
          Conduit.error(ctx, 401)
        end
      end
    end
  end
end

app.get "/api/user" do |ctx|
  Conduit.handle(ctx) do
    Conduit::Reads.enqueue(ctx, 8, Conduit.auth(ctx))
  end
end

app.put "/api/user" do |ctx|
  Conduit.handle(ctx) do
    Conduit.auth(ctx)
    m = Conduit.body(ctx, "user")
    # Validate every field before starting a write or password job.
    {"email", "username", "password"}.each { |key| Conduit.field(ctx, m, key) }
    {"bio", "image"}.each { |key| Conduit.field(ctx, m, key, nonempty: false) }
    Conduit.state(ctx).scratch.clear
    if pw = Conduit.field(ctx, m, "password")
      Passwords.acquire(ctx, pw, 2)
    else
      Conduit.update_user(ctx)
    end
  end
end

app.get "/api/profiles/:username" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx, false)
    Conduit::Reads.enqueue(ctx, 9, viewer, key: Conduit.decode(ctx, ctx.param("username")))
  end
end

{% for method, index in {post: 6, delete: 7} %}
  app.{{method}} "/api/profiles/:username/follow" do |ctx|
    Conduit.handle(ctx) do
      viewer = Conduit.auth(ctx)
      ctx.db.query(Sql::{{ {6 => "FOLLOW", 7 => "UNFOLLOW", 26 => "FAVORITE", 27 => "UNFAVORITE"}[index].id }}, viewer, Conduit.decode(ctx, ctx.param("username"))) do |res, ctx|
        unless res.error?
          if row = res.first?
            ctx.json profile: Conduit.profile(row, 0, {{index == 6}})
          else
            Conduit.error(ctx, 404)
          end
        end
      end
    end
  end
{% end %}

app.get "/api/articles" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx, false)
    limit, offset = Conduit.page(ctx)
    kind = 0
    {"tag", "author", "favorited"}.each_with_index do |key, i|
      if kind == 0 && !ctx.query(key).empty?
        kind = i + 1
      end
    end
    value = kind == 0 ? Bytes.empty : Conduit.decode(ctx, ctx.query({"tag", "author", "favorited"}[kind - 1]))
    Conduit::Reads.enqueue(ctx, kind, viewer, limit, offset, value)
  end
end

app.get "/api/articles/feed" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx)
    limit, offset = Conduit.page(ctx)
    Conduit::Reads.enqueue(ctx, 4, viewer, limit, offset)
  end
end

app.get "/api/articles/:slug" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx, false)
    Conduit::Reads.enqueue(ctx, 5, viewer, key: Conduit.decode(ctx, ctx.param("slug")))
  end
end

app.post "/api/articles" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx)
    m = Conduit.body(ctx, "article")
    title = Conduit.field(ctx, m, "title", true).not_nil!
    description = Conduit.field(ctx, m, "description", true).not_nil!
    text = Conduit.field(ctx, m, "body", true).not_nil!
    tags = Conduit.state(ctx).tags
    tags.clear
    begin
      m.object do |key, value|
        if key.string_equals?("tagList") && !value.null?
          raise Conduit::Invalid.new unless value.array?
          value.array do |tag|
            raise Conduit::Invalid.new unless tag.string?
            b = Conduit.state(ctx).scratch
            t = tag.string(Bytes.new(b.tail, b.cap - b.len))
            raise Conduit::Invalid.new if t.empty?
            tags.add(t)
          end
        end
      end
      ctx.db.query(Conduit::CREATE, viewer, title, description, text, tags.param) do |res, ctx|
        unless res.error?
          if row = res.first?
            ctx.status 201
            Conduit.fetch_article(ctx, row.i64(0))
          end
        end
      end
    ensure
      tags.clear
    end
  end
end

app.put "/api/articles/:slug" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx)
    m = Conduit.body(ctx, "article")
    title = Conduit.field(ctx, m, "title")
    description = Conduit.field(ctx, m, "description")
    text = Conduit.field(ctx, m, "body")
    ctx.db.query(Sql::UPDATE_ARTICLE, Conduit.decode(ctx, ctx.param("slug")), title, description, text, viewer) do |res, ctx|
      unless res.error?
        if row = res.first?
          if row.i64(1) == Conduit.state(ctx).viewer
            Conduit.fetch_article(ctx, row.i64(0))
          else
            Conduit.error(ctx, 403)
          end
        else
          Conduit.error(ctx, 404)
        end
      end
    end
  end
end

app.delete "/api/articles/:slug" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx)
    ctx.db.query(Sql::DELETE_ARTICLE, Conduit.decode(ctx, ctx.param("slug")), viewer) { |res, ctx| Conduit.deleted(ctx, res) }
  end
end

{% for method, index in {post: 26, delete: 27} %}
  app.{{method}} "/api/articles/:slug/favorite" do |ctx|
    Conduit.handle(ctx) do
      viewer = Conduit.auth(ctx)
      ctx.db.query(Sql::{{ {6 => "FOLLOW", 7 => "UNFOLLOW", 26 => "FAVORITE", 27 => "UNFAVORITE"}[index].id }}, viewer, Conduit.decode(ctx, ctx.param("slug"))) do |res, ctx|
        Conduit.fetch_slug(ctx) unless res.error?
      end
    end
  end
{% end %}

app.get "/api/articles/:slug/comments" do |ctx|
  Conduit.handle(ctx) do
    Conduit.auth(ctx, false)
    Conduit::Reads.enqueue(ctx, 6, Conduit.state(ctx).viewer, key: Conduit.decode(ctx, ctx.param("slug")))
  end
end

app.post "/api/articles/:slug/comments" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx)
    text = Conduit.field(ctx, Conduit.body(ctx, "comment"), "body", true).not_nil!
    ctx.db.query(Sql::ADD_COMMENT, Conduit.decode(ctx, ctx.param("slug")), viewer, text) do |res, ctx|
      unless res.error?
        if row = res.first?
          ctx.status 201
          ctx.json comment: Conduit.comment(ctx, row, false)
        else
          Conduit.error(ctx, 404)
        end
      end
    end
  end
end

app.delete "/api/articles/:slug/comments/:id" do |ctx|
  Conduit.handle(ctx) do
    viewer = Conduit.auth(ctx)
    id = Conduit.uint(ctx.param("id"))
    raise Conduit::Invalid.new(404) unless id
    ctx.db.query(Sql::DELETE_COMMENT, id, Conduit.decode(ctx, ctx.param("slug")), viewer) { |res, ctx| Conduit.deleted(ctx, res) }
  end
end

workers = (ENV["WORKERS"]? || Rayo::Sys.ncpu.to_s).to_i
raise "WORKERS must be between 1 and 31" unless 1 <= workers <= 31
pool = (ENV["PG_CONNS"]? || (95 // workers - 2).clamp(1, 2).to_s).to_i
raise "connection budget exceeds 95" unless pool > 0 && workers * (pool + 2) <= 95
app.run host: ENV.fetch("HOST", "127.0.0.1"), port: ENV.fetch("PORT", "3000").to_i,
  workers: workers, database: ENV["DATABASE_URL"], pool: pool
