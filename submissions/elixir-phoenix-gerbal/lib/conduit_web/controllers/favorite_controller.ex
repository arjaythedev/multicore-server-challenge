defmodule ConduitWeb.FavoriteController do
  use ConduitWeb, :controller

  alias Conduit.Blog

  def create(conn, %{"slug" => slug}) do
    with {:ok, article} <- Blog.favorite_article(slug, conn.assigns.current_user_id) do
      conn
      |> put_view(ConduitWeb.ArticleJSON)
      |> render(:show, article: article)
    end
  end

  def delete(conn, %{"slug" => slug}) do
    with {:ok, article} <- Blog.unfavorite_article(slug, conn.assigns.current_user_id) do
      conn
      |> put_view(ConduitWeb.ArticleJSON)
      |> render(:show, article: article)
    end
  end
end
