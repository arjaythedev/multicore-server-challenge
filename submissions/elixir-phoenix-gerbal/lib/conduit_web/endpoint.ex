defmodule ConduitWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :conduit

  # Phoenix.Ecto.CheckRepoStatus, which `mix phx.new` also plugs here, is left out: it checks for pending migrations
  # through Ecto.Migrator, which creates a schema_migrations table, and the schema is fixed (rule 3).
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug ConduitWeb.Plugs.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug ConduitWeb.Router
end
