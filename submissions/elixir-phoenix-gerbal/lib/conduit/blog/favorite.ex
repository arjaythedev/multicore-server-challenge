defmodule Conduit.Blog.Favorite do
  @moduledoc false
  use Ecto.Schema

  alias Conduit.Accounts.User
  alias Conduit.Blog.Article

  @primary_key false
  schema "favorites" do
    belongs_to :user, User, primary_key: true
    belongs_to :article, Article, primary_key: true
  end
end
