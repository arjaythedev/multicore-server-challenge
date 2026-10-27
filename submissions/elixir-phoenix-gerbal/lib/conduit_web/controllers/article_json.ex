defmodule ConduitWeb.ArticleJSON do
  alias Conduit.Blog.Article
  alias ConduitWeb.ProfileJSON
  alias ConduitWeb.Timestamps

  @doc "A page of articles. Lists leave out each article's body."
  def index(%{articles: articles, count: count}) do
    %{articles: for(article <- articles, do: summary(article)), articlesCount: count}
  end

  def show(%{article: %Article{} = article}) do
    %{article: article |> summary() |> Map.put(:body, article.body)}
  end

  defp summary(%Article{} = article) do
    %{
      slug: article.slug,
      title: article.title,
      description: article.description,
      tagList: article.tag_list,
      createdAt: Timestamps.format(article.created_at),
      updatedAt: Timestamps.format(article.updated_at),
      favorited: article.favorited,
      favoritesCount: article.favorites_count,
      author: ProfileJSON.data(article.author)
    }
  end
end
