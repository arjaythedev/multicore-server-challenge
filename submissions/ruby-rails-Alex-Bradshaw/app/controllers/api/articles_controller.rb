class Api::ArticlesController < ApplicationController
  before_action :optional_auth, only: %i[index show]
  before_action :require_auth!, only: %i[feed create update destroy favorite unfavorite]

  # GET /api/articles?tag=&author=&favorited=&limit=&offset=
  def index
    limit, offset = pagination
    return unless limit # pagination already rendered the 422

    articles, count = ArticleQuery.list(viewer_id, list_filter, limit, offset)
    render json: { articles: articles, articlesCount: count }
  end

  # GET /api/articles/feed?limit=&offset=
  def feed
    limit, offset = pagination
    return unless limit

    articles, count = ArticleQuery.feed(viewer_id, limit, offset)
    render json: { articles: articles, articlesCount: count }
  end

  # GET /api/articles/:slug
  def show
    article = ArticleQuery.find_by_slug(viewer_id, params[:slug])
    return render_error(:not_found, "article not found") unless article

    render json: { article: article }
  end

  # POST /api/articles
  def create
    attrs = article_params
    return render_error(:unprocessable_content, "article must be an object") unless attrs

    title, description, body = Article::TEXT_FIELDS.map { |field| attrs[field] }
    unless [title, description, body].all? { |value| non_empty_string?(value) }
      return render_error(:unprocessable_content, "title, description and body must be non-empty strings")
    end

    tags = attrs[:tagList]
    tags = [] if tags.nil? # absent or null: no tags
    unless tags.is_a?(Array) && tags.all? { |tag| non_empty_string?(tag) }
      return render_error(:unprocessable_content, "tagList must be an array of non-empty strings")
    end

    id = Article.transaction { insert_article(title, description, body, tags) }
    render json: { article: ArticleQuery.find_by_id(viewer_id, id) }, status: :created
  end

  # PUT /api/articles/:slug
  def update
    attrs = article_params
    return render_error(:unprocessable_content, "article must be an object") unless attrs

    changes = Article::TEXT_FIELDS.index_with { |field| attrs[field] } # absent and null both come through as nil
    unless changes.values.all? { |value| value.nil? || non_empty_string?(value) }
      return render_error(:unprocessable_content, "title, description and body must be non-empty strings")
    end

    id = load_own_article_id or return

    # A new title also gives the article a new slug (SLUGIFY(title) || '-' || id); updated_at always moves.
    ActiveRecord::Base.connection.exec_query(<<~SQL, "Article Update", [id, changes[:title], changes[:description], changes[:body]])
      UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
             slug = CASE WHEN $2::text IS NULL THEN slug ELSE #{slugify_sql("$2")} || '-' || id END,
             updated_at = now()
       WHERE id = $1
    SQL
    render json: { article: ArticleQuery.find_by_id(viewer_id, id) }
  end

  # DELETE /api/articles/:slug
  def destroy
    id = load_own_article_id or return

    # Comments, favorites and tag links go with it: the schema's foreign keys are ON DELETE CASCADE.
    Article.where(id: id).delete_all
    head :no_content
  end

  # POST /api/articles/:slug/favorite
  def favorite
    id = Article.where(slug: params[:slug]).pick(:id)
    return render_error(:not_found, "article not found") unless id

    Favorite.insert({ user_id: viewer_id, article_id: id }) # ON CONFLICT DO NOTHING: favoriting twice is fine
    render json: { article: ArticleQuery.find_by_id(viewer_id, id) }
  end

  # DELETE /api/articles/:slug/favorite
  def unfavorite
    id = Article.where(slug: params[:slug]).pick(:id)
    return render_error(:not_found, "article not found") unless id

    Favorite.where(user_id: viewer_id, article_id: id).delete_all
    render json: { article: ArticleQuery.find_by_id(viewer_id, id) }
  end

  private

  # Only the first of tag, author, favorited applies; an empty value (e.g. "?tag=") counts as not given.
  def list_filter
    %i[tag author favorited].each do |kind|
      value = params[kind]
      return [kind, value] if non_empty_string?(value)
    end
    nil
  end

  # The {"article": {...}} wrapper, or nil if it's missing or not an object.
  def article_params
    attrs = params[:article]
    attrs if attrs.is_a?(ActionController::Parameters)
  end

  # Finds the article for an update or delete: 404 if there's no such slug, 403 if the viewer isn't its author.
  # Returns its id, or nil after rendering the error.
  def load_own_article_id
    id, author_id = Article.where(slug: params[:slug]).pick(:id, :author_id)
    if id.nil?
      render_error(:not_found, "article not found")
      nil
    elsif author_id != viewer_id
      render_error(:forbidden, "you are not the author of this article")
      nil
    else
      id
    end
  end

  # The create transaction from SPEC.md: the article (its slug uses the id it's about to get), then its tags.
  # Tags are passed to Postgres as a JSON array, so no array-encoding is needed on the Ruby side.
  def insert_article(title, description, body, tags)
    # exec_query rather than select_value: Rails treats exec_query as a write, so it isn't served from the
    # per-request query cache.
    connection = ActiveRecord::Base.connection
    id = connection.exec_query(<<~SQL, "Article Create", [viewer_id, title, description, body]).rows.first.first
      INSERT INTO articles (id, slug, author_id, title, description, body)
      SELECT n.id, #{slugify_sql("$2")} || '-' || n.id, $1, $2, $3, $4
        FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
      RETURNING id
    SQL
    return id if tags.empty?

    tags_json = tags.to_json
    connection.exec_query(<<~SQL, "Tag Create", [tags_json])
      INSERT INTO tags (name) SELECT DISTINCT name FROM json_array_elements_text($1::json) AS name
      ON CONFLICT (name) DO NOTHING
    SQL
    connection.exec_query(<<~SQL, "Article Tags Create", [id, tags_json])
      INSERT INTO article_tags (article_id, tag_id)
      SELECT $1, t.id FROM tags t WHERE t.name IN (SELECT json_array_elements_text($2::json))
    SQL
    id
  end

  # SLUGIFY(x) from the spec, done in SQL so it comes out byte-identical to the reference.
  def slugify_sql(param)
    "trim(both '-' from lower(regexp_replace(#{param}, '[^A-Za-z0-9]+', '-', 'g')))"
  end

  def non_empty_string?(value)
    value.is_a?(String) && !value.empty?
  end
end
