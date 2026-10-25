require "json"

module Conduit
  # The Rack app: routes each request to its endpoint, which runs its statement and responds with the JSON that
  # Postgres built. Collaborators come in from config.ru: `db` (Database), `tokens` (Tokens) and `passwords`
  # (Passwords).
  App = Data.define(:db, :tokens, :passwords)

  class App
    ANONYMOUS = [0, nil].freeze

    def self.error(status, message)
      body = JSON.generate({ errors: { body: [message] } }).freeze
      [status, body].freeze
    end

    UNAUTHORIZED = error(401, "unauthorized")
    FORBIDDEN = error(403, "forbidden")
    NOT_FOUND = error(404, "not found")
    UNPROCESSABLE = error(422, "unprocessable entity")
    NO_CONTENT = [204, nil].freeze

    def call(env)
      status, body = route(env)
      headers = body ? { "content-type" => "application/json", "content-length" => body.bytesize.to_s } : {}
      [status, headers, body ? [body] : []]
    end

    private

    # [status, body], where body is the response's JSON or nil for no body.
    def route(env)
      path = env["PATH_INFO"]
      return NOT_FOUND unless path.start_with?("/api/")

      segments = path.byteslice(5, path.bytesize).split("/").map! { Input.segment(it) }
      return NOT_FOUND unless segments.all?

      case [env["REQUEST_METHOD"], *segments]
      in ["GET", "tags"] then ok(db.value(:tags))
      in ["POST", "users"] then register(env)
      in ["POST", "users", "login"] then login(env)
      in ["GET", "user"] then signed_in(env) { |viewer, token| current_user(viewer, token) }
      in ["PUT", "user"] then signed_in(env) { |viewer, token| update_user(env, viewer, token) }
      in ["GET", "profiles", username] then maybe_signed_in(env) { found(db.value(:profile, it, username)) }
      in ["POST", "profiles", username, "follow"] then signed_in(env) { found(db.value(:follow, it, username)) }
      in ["DELETE", "profiles", username, "follow"] then signed_in(env) { found(db.value(:unfollow, it, username)) }
      in ["GET", "articles"] then maybe_signed_in(env) { list_articles(env, it) }
      in ["GET", "articles", "feed"] then signed_in(env) { feed(env, it) }
      in ["POST", "articles"] then signed_in(env) { create_article(env, it) }
      in ["GET", "articles", slug] then maybe_signed_in(env) { found(db.value(:article, it, slug)) }
      in ["PUT", "articles", slug] then signed_in(env) { update_article(env, it, slug) }
      in ["DELETE", "articles", slug] then signed_in(env) { deleted(db.query(:delete_article, it, slug)) }
      in ["POST", "articles", slug, "favorite"] then signed_in(env) { found(db.value(:favorite, it, slug)) }
      in ["DELETE", "articles", slug, "favorite"] then signed_in(env) { found(db.value(:unfavorite, it, slug)) }
      in ["GET", "articles", slug, "comments"] then maybe_signed_in(env) { found(db.value(:comments, it, slug)) }
      in ["POST", "articles", slug, "comments"] then signed_in(env) { add_comment(env, it, slug) }
      in ["DELETE", "articles", slug, "comments", id] then signed_in(env) { delete_comment(it, slug, id) }
      else NOT_FOUND
      end
    end

    # Authentication. RealWorld's scheme is "Authorization: Token <jwt>".

    # Yields the viewer's id and token; 401 without a valid token.
    def signed_in(env)
      viewer, token = authenticate(env)
      viewer&.positive? ? yield(viewer, token) : UNAUTHORIZED
    end

    # Yields the viewer's id, or 0 when there's no Authorization header; 401 if there's one and it's invalid.
    def maybe_signed_in(env)
      viewer, = authenticate(env)
      viewer ? yield(viewer) : UNAUTHORIZED
    end

    # [id, token]; ANONYMOUS without a header; nil when the header is invalid.
    def authenticate(env)
      header = env["HTTP_AUTHORIZATION"]
      return ANONYMOUS unless header
      return unless header.start_with?("Token ")

      token = header.byteslice(6, header.bytesize)
      id = tokens.user_id(token)
      [id, token] if id
    end

    # Responses.

    def ok(body) = [200, body]

    # 200 with the statement's JSON, or 404 when it found nothing.
    def found(body) = body ? [200, body] : NOT_FOUND

    # For the delete statements: no row means nothing to delete, false means it isn't the viewer's.
    def deleted(result)
      return NOT_FOUND if result.ntuples.zero?

      result.getvalue(0, 0) == "t" ? NO_CONTENT : FORBIDDEN
    end

    def user(status, row, token)
      json = { email: row["email"], token:, username: row["username"], bio: row["bio"], image: row["image"] }
      [status, JSON.generate({ user: json })]
    end

    # Users and auth.

    def register(env)
      fields = Input.string_fields(Input.body(env, "user"), required: %w[username email password])
      return UNPROCESSABLE unless fields && passwords.acceptable?(fields["password"])

      password_hash = passwords.hash(fields["password"])
      result = unless_taken { db.query(:register, fields["username"], fields["email"], password_hash) }
      return UNPROCESSABLE unless result

      row = result.first
      user(201, row, tokens.issue(row["id"]))
    end

    def login(env)
      fields = Input.string_fields(Input.body(env, "user"), required: %w[email password])
      return UNPROCESSABLE unless fields

      row = db.query(:login, fields["email"]).first
      return UNAUTHORIZED unless row && passwords.verify?(fields["password"], row["password_hash"])

      user(200, row, tokens.issue(row["id"]))
    end

    def current_user(viewer, token)
      row = db.query(:current_user, viewer).first
      row ? user(200, row, token) : UNAUTHORIZED
    end

    def update_user(env, viewer, token)
      fields = Input.string_fields(Input.body(env, "user"), optional: %w[email username password bio image],
                                                            blank_ok: %w[bio image])
      return UNPROCESSABLE unless fields && (fields["password"].nil? || passwords.acceptable?(fields["password"]))

      password_hash = fields["password"] && passwords.hash(fields["password"])
      result = unless_taken {
        db.query(:update_user, viewer, fields["email"], fields["username"], password_hash, fields["bio"], fields["image"])
      }
      return UNPROCESSABLE unless result

      row = result.first
      row ? user(200, row, token) : UNAUTHORIZED
    end

    # The statement's result, or nil if it would have taken a unique username or email.
    def unless_taken
      yield
    rescue PG::UniqueViolation
      nil
    end

    # Articles.

    # Only the first of tag, author and favorited applies; an empty one counts as not given.
    FILTERS = { "tag" => :list_tag, "author" => :list_author, "favorited" => :list_favorited }.freeze

    def list_articles(env, viewer)
      query = Input.query(env)
      limit, offset = Input.page(query)
      return UNPROCESSABLE unless limit

      param, statement = FILTERS.find { |name, _| !query.fetch(name, "").empty? }
      ok(param ? db.value(statement, viewer, limit, offset, query[param]) : db.value(:list_all, viewer, limit, offset))
    end

    def feed(env, viewer)
      limit, offset = Input.page(Input.query(env))
      limit ? ok(db.value(:feed, viewer, limit, offset)) : UNPROCESSABLE
    end

    def create_article(env, viewer)
      input = Input.body(env, "article")
      fields = Input.string_fields(input, required: %w[title description body])
      tag_names = Input.string_list(input, "tagList")
      return UNPROCESSABLE unless fields && tag_names

      id = db.transaction { |run|
        id = run.(:insert_article, viewer, fields["title"], fields["description"], fields["body"]).getvalue(0, 0)
        unless tag_names.empty?
          names = Database.array(tag_names)
          run.(:insert_tags, names)
          run.(:tag_article, id, names)
        end
        id
      }
      [201, db.value(:article_by_id, viewer, id)]
    end

    def update_article(env, viewer, slug)
      fields = Input.string_fields(Input.body(env, "article"), optional: %w[title description body])
      return UNPROCESSABLE unless fields

      result = db.query(:update_article, viewer, slug, fields["title"], fields["description"], fields["body"])
      return NOT_FOUND if result.ntuples.zero?

      body = result.getvalue(0, 0)
      body ? ok(body) : FORBIDDEN
    end

    # Comments.

    COMMENT_ID = /\A[0-9]{1,18}\z/

    def add_comment(env, viewer, slug)
      fields = Input.string_fields(Input.body(env, "comment"), required: %w[body])
      return UNPROCESSABLE unless fields

      body = db.value(:add_comment, viewer, slug, fields["body"])
      body ? [201, body] : NOT_FOUND
    end

    # Only a plain decimal id can name a comment; anything else is a comment that doesn't exist.
    def delete_comment(viewer, slug, id)
      id.match?(COMMENT_ID) ? deleted(db.query(:delete_comment, viewer, slug, id)) : NOT_FOUND
    end
  end
end
