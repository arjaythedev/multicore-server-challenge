defmodule ConduitWeb.UserJSON do
  alias Conduit.Accounts.User

  def show(%{user: %User{} = user, token: token}) do
    %{user: %{email: user.email, token: token, username: user.username, bio: user.bio, image: user.image}}
  end
end
