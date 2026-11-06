class CommentsController < ApplicationController
  allow_anonymous only: :index

  def index
    comments = Comment.thread(viewer_id, Article.id_for!(params[:article_slug]))
    render json: { comments: comments.map { ConduitJson.comment(it, author: ConduitJson.author(it)) } }
  end

  def create
    fields = string_fields(body_object(:comment), required: %i[body])
    return unprocessable unless fields

    comment = Comment.create(article_id: Article.id_for!(params[:article_slug]), author_id: viewer_id, body: fields[:body])
    author = ConduitJson.profile(User[viewer_id], following: false)
    render json: { comment: ConduitJson.comment(comment, author:) }, status: :created
  end

  def destroy
    comment = Comment.join(:articles, id: :article_id).where(Sequel[:articles][:slug] => params[:article_slug])
      .select(Sequel[:comments][:id], Sequel[:comments][:author_id]).first(Sequel[:comments][:id] => comment_id)
    raise Sequel::NoMatchingRow unless comment
    return forbidden unless comment.author_id == viewer_id

    comment.delete
    head :no_content
  end

  private

  # Only a plain decimal id can name a comment; anything else is a comment that doesn't exist.
  def comment_id
    params[:id].match?(/\A[0-9]{1,18}\z/) ? params[:id].to_i : raise(Sequel::NoMatchingRow)
  end
end
