defmodule ConduitWeb.ProfileJSON do
  alias Conduit.Accounts.User

  def show(%{profile: %User{} = user}), do: %{profile: data(user)}

  @doc "A user as a public profile; also an article's or comment's `author`."
  def data(%User{} = user) do
    %{username: user.username, bio: user.bio, image: user.image, following: user.following}
  end
end
