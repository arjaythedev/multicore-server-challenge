defmodule Conduit.Blog.Comment do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  alias Conduit.Accounts.User
  alias Conduit.Blog.Article

  @type t :: %__MODULE__{}

  schema "comments" do
    field :body, :string

    belongs_to :article, Article
    belongs_to :author, User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "A changeset for a new comment: the body is required. The article may have been deleted since it was looked up."
  def changeset(comment, attrs) do
    comment
    # Any non-empty string is a body, even one of only whitespace, so values aren't trimmed before the blank check.
    |> cast(attrs, [:body], trim_values: fn _type, value -> value end)
    |> validate_required([:body])
    |> foreign_key_constraint(:article_id)
  end
end
