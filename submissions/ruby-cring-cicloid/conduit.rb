# frozen_string_literal: true

require "json"
require "uri"
require_relative "auth"
require_relative "db"
require_relative "sql"
require_relative "planner"

# The Conduit API (SPEC.md) on a plain interface: #call(method, target, authorization, body) returns
# [status, document]. `target` is the request target (path and query), `authorization` the header value
# or nil, `body` the request body or nil. The HTTP layer owns framing and keep-alive.
class Conduit
  def self.error(message) = %({"errors":{"body":[#{JSON.generate(message)}]}}).freeze

  UNAUTHORIZED = [401, error("unauthorized")].freeze
  FORBIDDEN = [403, error("forbidden")].freeze
  NOT_FOUND = [404, error("not found")].freeze
  INVALID = [422, error("invalid request")].freeze
  TAKEN = [422, error("username or email has already been taken")].freeze
  NO_CONTENT = [204, ""].freeze
  EMPTY = "".freeze

  PREFIX = "/api/"
  ARTICLES = "articles"
  PROFILES = "profiles"
  GET = "GET"
  POST = "POST"
  PUT = "PUT"
  DELETE = "DELETE"
  INT64 = /\A[0-9]{1,19}\z/
  INT64_MAX = (2**63) - 1
  DEFAULT_LIMIT = "20"
  ZERO = "0"
  MAX_PASSWORD = Bcrypt::MAX # longer passwords are refused rather than truncated

  # `planner`: where reads go (RemotePlanner::Client); by default a Planner in this process.
  def initialize(db, secret, planner: nil)
    @db = db
    @planner = planner || Planner.new(db)
    @tokens = Tokens.new(secret)
    @array = PG::TextEncoder::Array.new
  end

  def call(method, target, authorization, body)
    query_at = target.index("?")
    path = query_at ? target.byteslice(0, query_at) : target
    return NOT_FOUND unless path.start_with?(PREFIX)

    route(method, path, query_at && target.byteslice(query_at + 1, target.bytesize - query_at - 1), authorization, body)
  rescue DB::Failed => error
    case error.sqlstate
    when "23505" then TAKEN
    when "23503" then UNAUTHORIZED # a token for a user that no longer exists
    when /\A22/ then INVALID # bad input that only Postgres caught (invalid UTF-8, out-of-range number)
    else raise
    end
  end

  private

  # /api/<a>[/<b>[/<c>[/<d>]]]
  def route(method, path, query, authorization, body)
    parts = path.byteslice(5, path.bytesize - 5).split("/", -1)
    parts.pop if parts.size > 1 && parts.last.empty? # a trailing slash
    head = parts[0]
    case parts.size
    when 1
      case head
      when ARTICLES
        if method == GET then list(query, authorization)
        elsif method == POST then create_article(authorization, body)
        else NOT_FOUND
        end
      when "tags" then method == GET ? [200, @planner.tags] : NOT_FOUND
      when "user"
        if method == GET then current_user(authorization)
        elsif method == PUT then update_user(authorization, body)
        else NOT_FOUND
        end
      when "users" then method == POST ? register(body) : NOT_FOUND
      else NOT_FOUND
      end
    when 2
      second = decode(parts[1])
      case head
      when ARTICLES
        if second == "feed" && method == GET then feed(query, authorization)
        elsif method == GET then article(second, authorization)
        elsif method == PUT then update_article(second, authorization, body)
        elsif method == DELETE then delete_article(second, authorization)
        else NOT_FOUND
        end
      when PROFILES then method == GET ? profile(second, authorization) : NOT_FOUND
      when "users" then second == "login" && method == POST ? login(body) : NOT_FOUND
      else NOT_FOUND
      end
    when 3
      second = decode(parts[1])
      case head
      when ARTICLES
        case parts[2]
        when "favorite"
          if method == POST then favorite(:favorite, second, authorization)
          elsif method == DELETE then favorite(:unfavorite, second, authorization)
          else NOT_FOUND
          end
        when "comments"
          if method == GET then comments(second, authorization)
          elsif method == POST then create_comment(second, authorization, body)
          else NOT_FOUND
          end
        else NOT_FOUND
        end
      when PROFILES
        return NOT_FOUND unless parts[2] == "follow"

        if method == POST then follow(:follow, second, authorization)
        elsif method == DELETE then follow(:unfollow, second, authorization)
        else NOT_FOUND
        end
      else NOT_FOUND
      end
    when 4
      return NOT_FOUND unless head == ARTICLES && parts[2] == "comments" && method == DELETE

      delete_comment(decode(parts[1]), parts[3], authorization)
    else NOT_FOUND
    end
  end

  # --- auth ---------------------------------------------------------------------------------------

  # The viewer for an auth-optional endpoint: 0 when there is no header, nil when it is invalid.
  def viewer(authorization)
    return 0 unless authorization

    @tokens.verify(authorization)
  end

  # --- users --------------------------------------------------------------------------------------

  def register(body)
    user = wrapped(body, "user") or return INVALID
    username = user["username"]
    email = user["email"]
    password = user["password"]
    return INVALID unless filled?(username) && filled?(email) && filled?(password) && password.bytesize <= MAX_PASSWORD

    hash = Bcrypt.create(password) or return INVALID
    result = @db.query(:register, [username, email, hash])
    row = result.values.first
    result.clear
    [201, user_document(row[0], row[1], row[2], row[3], row[4])]
  end

  def login(body)
    user = wrapped(body, "user") or return INVALID
    email = user["email"]
    password = user["password"]
    return INVALID unless filled?(email) && filled?(password)

    result = @db.query(:login, [email])
    row = result.values.first
    result.clear
    return UNAUTHORIZED unless row && Bcrypt.verify(password, row[5])

    [200, user_document(row[0], row[1], row[2], row[3], row[4])]
  end

  def user_document(id, username, email, bio, image)
    JSON.generate({ "user" => { "email" => email, "token" => @tokens.issue(id), "username" => username,
                                "bio" => bio, "image" => image } })
  end

  def current_user(authorization)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED

    _, username, email, bio, image = @planner.user(id) || (return UNAUTHORIZED)
    [200, JSON.generate({ "user" => { "email" => email, "token" => Tokens.token_of(authorization), "username" => username,
                                      "bio" => bio, "image" => image } })]
  end

  def update_user(authorization, body)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED
    user = wrapped(body, "user") or return INVALID
    email, username, password, bio, image = user.values_at("email", "username", "password", "bio", "image")
    return INVALID unless optional_filled?(email) && optional_filled?(username) && optional_filled?(password) &&
                          optional_string?(bio) && optional_string?(image)
    return INVALID if password && password.bytesize > MAX_PASSWORD

    hash = password && (Bcrypt.create(password) or return INVALID)
    document = @db.value(:update_user, [id, email, username, hash, bio, image, Tokens.token_of(authorization)])
    document ? [200, document] : UNAUTHORIZED
  end

  # --- profiles -----------------------------------------------------------------------------------

  def profile(username, authorization)
    viewer = viewer(authorization) or return UNAUTHORIZED

    document = @planner.profile(viewer, username) or return NOT_FOUND
    [200, document]
  end

  def follow(statement, username, authorization)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED

    document = @db.write_value(statement, [id, username]) or return NOT_FOUND
    [200, document]
  end

  # --- articles -----------------------------------------------------------------------------------

  def list(query, authorization)
    viewer = viewer(authorization) or return UNAUTHORIZED
    params = query_params(query) or return INVALID
    limit, offset = page(params) || (return INVALID)
    kind, value = if (tag = params["tag"]) && !tag.empty? then [:tag, tag]
                  elsif (author = params["author"]) && !author.empty? then [:author, author]
                  elsif (favorited = params["favorited"]) && !favorited.empty? then [:favorited, favorited]
                  else [:global, nil]
                  end
    [200, @planner.list(kind, viewer, value, limit, offset)]
  end

  def feed(query, authorization)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED
    params = query_params(query) or return INVALID
    limit, offset = page(params) || (return INVALID)

    [200, @planner.feed(id, limit, offset)]
  end

  def article(slug, authorization)
    viewer = viewer(authorization) or return UNAUTHORIZED

    document = @planner.article(viewer, slug) or return NOT_FOUND
    [200, document]
  end

  def create_article(authorization, body)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED
    article = wrapped(body, "article") or return INVALID
    title, description, text, tags = article.values_at("title", "description", "body", "tagList")
    return INVALID unless filled?(title) && filled?(description) && filled?(text)
    return INVALID unless tags.nil? || (tags.is_a?(Array) && tags.all? { |tag| filled?(tag) })

    statements = [[:begin, []], [:create_article, [id, title, description, text]]]
    if tags && !tags.empty?
      encoded = @array.encode(tags)
      statements << [:create_tags, [encoded]] << [:tag_article, [encoded]]
    end
    statements << [:commit, []] << [:created_article, [id]]
    results = @db.group(statements)
    document = results.last.getvalue(0, 0)
    results.each(&:clear)
    [201, document]
  end

  def update_article(slug, authorization, body)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED
    article = wrapped(body, "article") or return INVALID
    title, description, text = article.values_at("title", "description", "body")
    return INVALID unless optional_filled?(title) && optional_filled?(description) && optional_filled?(text)

    result = @db.write(:update_article, [id, slug, title, description, text])
    if result.ntuples.zero?
      result.clear
      return NOT_FOUND
    end

    author = result.getvalue(0, 0).to_i
    document = result.getvalue(0, 1)
    result.clear
    author == id ? [200, document] : FORBIDDEN
  end

  def delete_article(slug, authorization)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED

    author = @db.write_value(:delete_article, [id, slug]) or return NOT_FOUND
    author.to_i == id ? NO_CONTENT : FORBIDDEN
  end

  # The write commits first; the article (favorited, the new count) is then read through the planner.
  def favorite(statement, slug, authorization)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED

    article = @db.write_value(statement, [id, slug]) or return NOT_FOUND
    document = @planner.article_by_id(id, article) or return NOT_FOUND # deleted in between
    [200, document]
  end

  # --- comments -----------------------------------------------------------------------------------

  def comments(slug, authorization)
    viewer = viewer(authorization) or return UNAUTHORIZED

    document = @planner.comments(viewer, slug) or return NOT_FOUND
    [200, document]
  end

  def create_comment(slug, authorization, body)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED
    comment = wrapped(body, "comment") or return INVALID
    text = comment["body"]
    return INVALID unless filled?(text)

    document = @db.write_value(:create_comment, [id, slug, text]) or return NOT_FOUND
    [201, document]
  end

  def delete_comment(slug, comment_id, authorization)
    id = authorization && @tokens.verify(authorization) or return UNAUTHORIZED
    return NOT_FOUND unless INT64.match?(comment_id) && comment_id.to_i <= INT64_MAX

    author = @db.write_value(:delete_comment, [id, slug, comment_id]) or return NOT_FOUND
    author.to_i == id ? NO_CONTENT : FORBIDDEN
  end

  # --- input --------------------------------------------------------------------------------------

  # The object under `key` in a JSON body, or nil.
  def wrapped(body, key)
    return nil unless body

    object = JSON.parse(body)
    inner = object[key] if object.is_a?(Hash)
    inner.is_a?(Hash) ? inner : nil
  rescue JSON::ParserError, EncodingError
    nil
  end

  def filled?(value) = value.is_a?(String) && !value.empty?

  def optional_filled?(value) = value.nil? || filled?(value)

  def optional_string?(value) = value.nil? || value.is_a?(String)

  # [limit, offset] as strings for Postgres, or nil when either is out of range.
  def page(params)
    limit = params.fetch("limit", DEFAULT_LIMIT)
    offset = params.fetch("offset", ZERO)
    return nil unless INT64.match?(limit) && INT64.match?(offset)

    l = limit.to_i
    o = offset.to_i
    return nil unless l >= 1 && l <= 100 && o <= INT64_MAX

    [l.to_s, o.to_s]
  end

  # The query string as a hash (the first value of each name wins), or nil when it can't be decoded.
  def query_params(query)
    params = {}
    return params unless query && !query.empty?

    query.split("&").each do |pair|
      name, value = pair.split("=", 2)
      next if name.nil? || name.empty?

      name = decode_component(name)
      params[name] = decode_component(value || EMPTY) unless params.key?(name)
    end
    params
  rescue ArgumentError
    nil
  end

  def decode_component(value)
    value.include?("%") || value.include?("+") ? URI.decode_www_form_component(value) : value
  end

  def decode(segment)
    segment.include?("%") ? URI.decode_uri_component(segment) : segment
  end
end
