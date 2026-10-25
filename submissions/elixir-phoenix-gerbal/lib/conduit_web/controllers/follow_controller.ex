defmodule ConduitWeb.FollowController do
  use ConduitWeb, :controller

  alias Conduit.Profiles

  def create(conn, %{"username" => username}) do
    with {:ok, profile} <- Profiles.follow(conn.assigns.current_user_id, username) do
      conn
      |> put_view(ConduitWeb.ProfileJSON)
      |> render(:show, profile: profile)
    end
  end

  def delete(conn, %{"username" => username}) do
    with {:ok, profile} <- Profiles.unfollow(conn.assigns.current_user_id, username) do
      conn
      |> put_view(ConduitWeb.ProfileJSON)
      |> render(:show, profile: profile)
    end
  end
end
