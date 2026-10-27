class Api::CommentsController < ApplicationController
  before_action :optional_auth, only: :index
  before_action :require_auth!, only: %i[create destroy]

  # GET /api/articles/:slug/comments: the newest 100 comments
  def index
    article_id = Article.where(slug: params[:slug]).pick(:id)
    return render_error(:not_found, "article not found") unless article_id

    rows = ActiveRecord::Base.connection.select_all(<<~SQL, "Comment Load", [viewer_id, article_id])
      SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
        FROM comments c JOIN users u ON u.id = c.author_id
       WHERE c.article_id = $2
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT 100
    SQL
    render json: { comments: rows.map { |row| comment_json(row) } }
  end

  # POST /api/articles/:slug/comments
  def create
    # The body is checked before the article lookup: an invalid body is a 422 even on an unknown article.
    attrs = params[:comment]
    body = attrs[:body] if attrs.is_a?(ActionController::Parameters)
    unless body.is_a?(String) && !body.empty?
      return render_error(:unprocessable_content, "comment must be an object with a non-empty body")
    end

    article_id = Article.where(slug: params[:slug]).pick(:id)
    return render_error(:not_found, "article not found") unless article_id

    row = ActiveRecord::Base.connection.exec_query(<<~SQL, "Comment Create", [article_id, viewer_id, body]).first
      WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
                 RETURNING id, body, created_at, updated_at, author_id)
      SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
        FROM c JOIN users u ON u.id = c.author_id
    SQL
    # Nobody can follow themselves, so the author of a new comment is never "followed" by its viewer.
    render json: { comment: comment_json(row.merge("following" => false)) }, status: :created
  end

  # DELETE /api/articles/:slug/comments/:id
  def destroy
    # A non-integer (or out-of-range) id can't match any comment, so it's a 404 like an unknown one.
    id = params[:id]
    return render_error(:not_found, "comment not found") unless id.match?(/\A\d{1,18}\z/)

    author_id = Comment.joins("JOIN articles a ON a.id = comments.article_id")
                       .where(id: id.to_i, a: { slug: params[:slug] })
                       .pick(:author_id)
    return render_error(:not_found, "comment not found") unless author_id
    return render_error(:forbidden, "you are not the author of this comment") unless author_id == viewer_id

    Comment.where(id: id.to_i).delete_all
    head :no_content
  end

  private

  # The Comment object from SPEC.md.
  def comment_json(row)
    {
      id: Integer(row["id"]),
      createdAt: ArticleQuery.timestamp(row["created_at"]),
      updatedAt: ArticleQuery.timestamp(row["updated_at"]),
      body: row["body"],
      author: {
        username: row["username"],
        bio: row["bio"],
        image: row["image"],
        following: ArticleQuery.boolean(row["following"])
      }
    }
  end
end
