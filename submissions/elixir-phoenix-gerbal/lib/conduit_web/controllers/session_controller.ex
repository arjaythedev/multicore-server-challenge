defmodule ConduitWeb.SessionController do
  use ConduitWeb, :controller

  alias Conduit.Accounts

  def create(conn, %{"user" => %{} = credentials}) do
    with {:ok, user} <- Accounts.authenticate(credentials) do
      token = Accounts.sign_token(user)

      conn
      |> put_view(ConduitWeb.UserJSON)
      |> render(:show, user: user, token: token)
    end
  end

  def create(_conn, _params), do: {:error, :invalid_body}
end
