defmodule Conduit.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [ConduitWeb.Telemetry, Conduit.Repo, ConduitWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: Conduit.Supervisor)
  end
end
