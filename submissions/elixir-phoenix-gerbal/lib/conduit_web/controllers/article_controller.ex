defmodule ConduitWeb.ArticleController do
  use ConduitWeb, :controller

  alias Conduit.Blog

  def index(conn, params) do
    with {:ok, %{articles: articles, count: count}} <- Blog.list_articles(params, conn.assigns.current_user_id) do
      render(conn, :index, articles: articles, count: count)
    end
  end

  def feed(conn, params) do
    with {:ok, %{articles: articles, count: count}} <- Blog.feed(params, conn.assigns.current_user_id) do
      render(conn, :index, articles: articles, count: count)
    end
  end

  def show(conn, %{"slug" => slug}) do
    with {:ok, article} <- Blog.get_article(slug, conn.assigns.current_user_id) do
      render(conn, :show, article: article)
    end
  end

  def create(conn, %{"article" => %{} = article_params}) do
    attrs = attrs(article_params)

    with {:ok, article} <- Blog.create_article(conn.assigns.current_user_id, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, article: article)
    end
  end

  def create(_conn, _params), do: {:error, :invalid_body}

  def update(conn, %{"slug" => slug, "article" => %{} = article_params}) do
    attrs = attrs(article_params)

    with {:ok, article} <- Blog.update_article(slug, conn.assigns.current_user_id, attrs) do
      render(conn, :show, article: article)
    end
  end

  def update(_conn, _params), do: {:error, :invalid_body}

  def delete(conn, %{"slug" => slug}) do
    with :ok <- Blog.delete_article(slug, conn.assigns.current_user_id) do
      send_resp(conn, :no_content, "")
    end
  end

  # The API's camelCase `tagList` is the schema's `tag_list`.
  defp attrs(params) do
    case Map.pop(params, "tagList") do
      {nil, params} -> params
      {tag_list, params} -> Map.put(params, "tag_list", tag_list)
    end
  end
end
