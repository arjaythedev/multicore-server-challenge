defmodule ConduitWeb.Plugs.Authenticate do
  @moduledoc """
  Reads `Authorization: Token <jwt>` and assigns `:current_user_id` (nil when anonymous) and `:token`.

  With `:required`, a missing or invalid token is a 401. With `:optional`, no header is anonymous, but a header that
  is present and invalid is still a 401.
  """
  @behaviour Plug

  import Plug.Conn

  alias Conduit.Accounts

  @impl Plug
  def init(mode) when mode in [:required, :optional], do: mode

  @impl Plug
  def call(conn, mode) do
    case {get_req_header(conn, "authorization"), mode} do
      {[], :optional} ->
        conn |> assign(:current_user_id, nil) |> assign(:token, nil)

      {["Token " <> token], _mode} ->
        case Accounts.verify_token(token) do
          {:ok, user_id} -> conn |> assign(:current_user_id, user_id) |> assign(:token, token)
          :error -> unauthorized(conn)
        end

      _missing_or_malformed ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> ConduitWeb.FallbackController.call({:error, :unauthorized})
    |> halt()
  end
end
