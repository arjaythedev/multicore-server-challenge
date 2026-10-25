defmodule Conduit.Profiles do
  @moduledoc "Public profiles and follows."

  import Ecto.Query

  alias Conduit.Accounts.User
  alias Conduit.Profiles.Follow
  alias Conduit.Repo

  @doc "Gets the profile for `username`, with `following` set for `viewer_id` (nil when anonymous)."
  @spec get_profile(String.t(), pos_integer() | nil) :: {:ok, User.t()} | {:error, :not_found}
  def get_profile(username, viewer_id) do
    query =
      from u in User,
        as: :author,
        where: u.username == ^username,
        select: %{u | following: exists(subquery(follows_author(viewer_id)))}

    query |> Repo.one() |> fetch()
  end

  @doc "Makes `follower_id` follow `username`. Following someone twice is fine."
  @spec follow(pos_integer(), String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def follow(follower_id, username) do
    with {:ok, user} <- fetch_user(username) do
      follow = %Follow{follower_id: follower_id, followee_id: user.id}
      Repo.insert!(follow, on_conflict: :nothing)
      {:ok, %{user | following: true}}
    end
  end

  @doc "Makes `follower_id` stop following `username`."
  @spec unfollow(pos_integer(), String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def unfollow(follower_id, username) do
    with {:ok, user} <- fetch_user(username) do
      follow = from f in Follow, where: f.follower_id == ^follower_id and f.followee_id == ^user.id
      Repo.delete_all(follow)
      {:ok, %{user | following: false}}
    end
  end

  # A subquery for `exists/1`: whether `viewer_id` follows the user bound as `:author` in the parent query. Anonymous
  # viewers (nil) are queried as id 0, which no user has, so they follow no one.
  defp follows_author(viewer_id) do
    from f in Follow, where: f.follower_id == ^(viewer_id || 0) and f.followee_id == parent_as(:author).id
  end

  defp fetch_user(username), do: User |> Repo.get_by(username: username) |> fetch()

  defp fetch(nil), do: {:error, :not_found}
  defp fetch(user), do: {:ok, user}
end
