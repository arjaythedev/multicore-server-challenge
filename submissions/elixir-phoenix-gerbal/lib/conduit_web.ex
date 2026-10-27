defmodule ConduitWeb do
  @moduledoc """
  The web interface: `use ConduitWeb, :controller`, `:router` or `:verified_routes`.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Phoenix.Controller
      import Plug.Conn
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      action_fallback ConduitWeb.FallbackController
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes, endpoint: ConduitWeb.Endpoint, router: ConduitWeb.Router
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
