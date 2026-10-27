defmodule ConduitWeb.TagJSON do
  def index(%{tags: tags}), do: %{tags: tags}
end
