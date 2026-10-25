import Config

# Cost 10 on every hash (rule 7).
config :bcrypt_elixir, log_rounds: 10

# Decoded text columns stay sub-binaries of the received packet instead of being copied. In prod every request's heap
# is collected when it ends (`gc_every_n_keepalive_requests` in config/runtime.exs), so nothing holds a packet for
# long; elsewhere a packet can outlive its request, which only costs memory.
config :conduit, Conduit.Repo, types: Conduit.PostgrexTypes

config :conduit, ConduitWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: ConduitWeb.ErrorJSON], layout: false]

config :conduit, ecto_repos: [Conduit.Repo]

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n", metadata: [:request_id]

# Elixir's built-in JSON (OTP's :json encoder), here and for Postgrex below: 4% less app CPU per request than Jason in
# interleaved runs.
config :phoenix, :json_library, JSON

config :postgrex, :json_library, JSON

import_config "#{config_env()}.exs"
