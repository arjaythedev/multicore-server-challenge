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
    @article_id = Article.id_for!(params[:article_slug])
  end

  def render_article
    render json: { article: ConduitJson.article(Article.presented_by_id(viewer_id, @article_id)) }
  end
end
