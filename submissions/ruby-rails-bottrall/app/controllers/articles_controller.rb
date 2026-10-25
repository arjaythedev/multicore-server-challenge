class ArticlesController < ApplicationController
  allow_anonymous only: %i[index show]

  def index
    page = page_params
    return unprocessable unless page

    filters = params.permit(:tag, :author, :favorited).to_h.symbolize_keys.compact_blank
    render_listing ArticleListing.filtered(**filters, **page)
  end

  def feed
    page = page_params
    return unprocessable unless page

    render_listing ArticleListing.feed(viewer_id, **page)
  end

  def show
    render_article Article.presented_for(viewer_id, body: true).find_by!(slug: params[:slug])
  end

  def create
    input = body_object("article")
    fields = string_fields(input, required: %i[title description body])
    tag_names = string_list(input, "tagList")
    return unprocessable unless fields && tag_names

    article = Article.publish(author_id: viewer_id, **fields, tag_names:)
    render_article presented(article.id), status: :created
  end

  def update
    fields = string_fields(body_object("article"), optional: %i[title description body])
    return unprocessable unless fields

    article = authored_article
    return forbidden unless article

    article.revise(**fields)
    render_article presented(article.id)
  end

  def destroy
    article = authored_article
    return forbidden unless article

    article.delete
    head :no_content
  end

  private

  # The article in the path if the viewer wrote it; 404 if there is no such article, nil if someone else wrote it.
  def authored_article
    article = Article.select(:id, :author_id).find_by!(slug: params[:slug])
    article if article.written_by?(viewer_id)
  end

  def presented(id) = Article.presented_for(viewer_id, body: true).find(id)

  def render_article(article, status: :ok)
    render json: { article: ConduitJson.article(article) }, status:
  end

  def render_listing(listing)
    articles = listing.articles_for(viewer_id).map { ConduitJson.article(it) }
    render json: { articles:, articlesCount: listing.total }
  end
end
