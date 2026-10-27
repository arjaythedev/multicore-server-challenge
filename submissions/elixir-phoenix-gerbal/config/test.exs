import Config

# Hashing at cost 10 in every test that registers a user would make the suite slow for no benefit.
config :bcrypt_elixir, log_rounds: 4

# The tests load ../../schema.sql into their own database (see the `test` alias in mix.exs) and run each test in a
# rolled-back sandbox transaction.
config :conduit, Conduit.Repo,
  url: System.get_env("TEST_DATABASE_URL", "postgres://postgres:postgres@localhost/conduit_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :conduit, ConduitWeb.Endpoint, http: [port: 4002], server: false

config :joken, default_signer: "test-secret"

config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation.
config :phoenix, :plug_init_mode, :runtime
