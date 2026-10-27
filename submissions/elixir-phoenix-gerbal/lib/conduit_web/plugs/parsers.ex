defmodule ConduitWeb.Plugs.Parsers do
  @moduledoc """
  `Plug.Parsers`, except that a body that isn't valid JSON gets the API's 422 like any other bad input, rather than
  Plug's 400.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    Plug.Parsers.ParseError ->
      conn
      |> ConduitWeb.FallbackController.call({:error, :invalid_body})
      |> Plug.Conn.halt()
  end
end
