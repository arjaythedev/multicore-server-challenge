class CommentsController < ApplicationController
  allow_anonymous only: :index

  def index
    comments = Comment.where(article_id: article_id).thread_for(viewer_id)
    render json: { comments: comments.map { ConduitJson.comment(it, author: ConduitJson.author(it)) } }
  end

  def create
    fields = string_fields(body_object("comment"), required: %i[body])
    return unprocessable unless fields

    comment = Comment.create!(article_id:, author_id: viewer_id, body: fields[:body])
    author = ConduitJson.profile(User.find(viewer_id), following: false)
    render json: { comment: ConduitJson.comment(comment, author:) }, status: :created
  end

  def destroy
    comment = Comment.joins(:article).where(articles: { slug: params[:article_slug] })
      .select(:id, :author_id).find_by!(id: comment_id)
    return forbidden unless comment.author_id == viewer_id

    comment.delete
    head :no_content
  end

  private

  def article_id
    Article.where(slug: params[:article_slug]).pick(:id) or raise ActiveRecord::RecordNotFound
  end

  # Only a plain decimal id can name a comment; anything else is a comment that doesn't exist.
  def comment_id
    params[:id].match?(/\A[0-9]{1,18}\z/) ? params[:id].to_i : raise(ActiveRecord::RecordNotFound)
  end
end
