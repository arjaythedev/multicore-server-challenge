class FavoritesController < ApplicationController
  before_action :set_article_id

  def create
    Favorite.favorite(viewer_id, @article_id)
    render_article
  end

  def destroy
    Favorite.unfavorite(viewer_id, @article_id)
    render_article
  end

  private

  def set_article_id
    @article_id = Article.where(slug: params[:article_slug]).pick(:id) or raise ActiveRecord::RecordNotFound
  end

  def render_article
    article = Article.presented_for(viewer_id, body: true).find(@article_id)
    render json: { article: ConduitJson.article(article) }
  end
end
