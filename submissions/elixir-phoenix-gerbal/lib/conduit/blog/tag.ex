defmodule Conduit.Blog.Tag do
  @moduledoc false
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "tags" do
    field :name, :string
  end
end
