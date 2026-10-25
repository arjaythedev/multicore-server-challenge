defmodule ConduitWeb.CommentController do
  use ConduitWeb, :controller

  alias Conduit.Blog

  def index(conn, %{"slug" => slug}) do
    with {:ok, comments} <- Blog.list_comments(slug, conn.assigns.current_user_id) do
      render(conn, :index, comments: comments)
    end
  end

  def create(conn, %{"slug" => slug, "comment" => %{} = comment_params}) do
    with {:ok, comment} <- Blog.create_comment(slug, conn.assigns.current_user_id, comment_params) do
      conn
      |> put_status(:created)
      |> render(:show, comment: comment)
    end
  end

  def create(_conn, _params), do: {:error, :invalid_body}

  def delete(conn, %{"slug" => slug, "id" => id}) do
    with :ok <- Blog.delete_comment(slug, id, conn.assigns.current_user_id) do
      send_resp(conn, :no_content, "")
    end
  end
end
