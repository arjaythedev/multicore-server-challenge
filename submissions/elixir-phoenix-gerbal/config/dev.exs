import Config

config :conduit, Conduit.Repo,
  url: System.get_env("DATABASE_URL", "postgres://conduit:conduit@localhost/conduit_dev"),
  pool_size: 10,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# `mix phx.server` recompiles changed code on the next request and shows errors with their stack traces.
config :conduit, ConduitWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  code_reloader: true,
  debug_errors: true

config :joken, default_signer: "dev-secret"

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :plug_init_mode, :runtime
config :phoenix, :stacktrace_depth, 20
