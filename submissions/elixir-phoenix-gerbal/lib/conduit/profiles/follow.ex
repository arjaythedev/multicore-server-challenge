defmodule Conduit.Profiles.Follow do
  @moduledoc false
  use Ecto.Schema

  alias Conduit.Accounts.User

  @primary_key false
  schema "follows" do
    belongs_to :follower, User, primary_key: true
    belongs_to :followee, User, primary_key: true
  end
end
