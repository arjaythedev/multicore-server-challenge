defmodule ConduitWeb.TagController do
  use ConduitWeb, :controller

  alias Conduit.Blog

  def index(conn, _params) do
    tags = Blog.list_tags()
    render(conn, :index, tags: tags)
  end
end
