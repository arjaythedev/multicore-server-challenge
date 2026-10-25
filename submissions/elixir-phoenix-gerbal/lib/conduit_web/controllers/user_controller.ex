defmodule ConduitWeb.UserController do
  use ConduitWeb, :controller

  alias Conduit.Accounts

  def create(conn, %{"user" => %{} = user_params}) do
    with {:ok, user} <- Accounts.register_user(user_params) do
      token = Accounts.sign_token(user)

      conn
      |> put_status(:created)
      |> render(:show, user: user, token: token)
    end
  end

  def create(_conn, _params), do: {:error, :invalid_body}

  def show(conn, _params) do
    with {:ok, user} <- current_user(conn) do
      render(conn, :show, user: user, token: conn.assigns.token)
    end
  end

  def update(conn, %{"user" => %{} = user_params}) do
    with {:ok, user} <- current_user(conn),
         {:ok, user} <- Accounts.update_user(user, user_params) do
      render(conn, :show, user: user, token: conn.assigns.token)
    end
  end

  def update(_conn, _params), do: {:error, :invalid_body}

  # A valid token for a user that no longer exists is unauthorized.
  defp current_user(conn) do
    case Accounts.get_user(conn.assigns.current_user_id) do
      nil -> {:error, :unauthorized}
      user -> {:ok, user}
    end
  end
end
