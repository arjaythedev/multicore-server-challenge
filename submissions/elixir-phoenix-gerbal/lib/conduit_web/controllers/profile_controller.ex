defmodule ConduitWeb.ProfileController do
  use ConduitWeb, :controller

  alias Conduit.Profiles

  def show(conn, %{"username" => username}) do
    with {:ok, profile} <- Profiles.get_profile(username, conn.assigns.current_user_id) do
      render(conn, :show, profile: profile)
    end
  end
end
