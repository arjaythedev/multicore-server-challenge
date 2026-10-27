defmodule ConduitWeb.CommentJSON do
  alias Conduit.Blog.Comment
  alias ConduitWeb.ProfileJSON
  alias ConduitWeb.Timestamps

  def index(%{comments: comments}), do: %{comments: for(comment <- comments, do: data(comment))}

  def show(%{comment: %Comment{} = comment}), do: %{comment: data(comment)}

  defp data(%Comment{} = comment) do
    %{
      id: comment.id,
      body: comment.body,
      createdAt: Timestamps.format(comment.created_at),
      updatedAt: Timestamps.format(comment.updated_at),
      author: ProfileJSON.data(comment.author)
    }
  end
end
