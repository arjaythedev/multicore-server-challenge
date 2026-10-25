import Config

if config_env() == :prod do
  {:ok, ip} = "HOST" |> System.get_env("127.0.0.1") |> String.to_charlist() |> :inet.parse_address()

  # The cores this node may run on (its CPU affinity), which start with fewer schedulers than that (rel/env.sh.eex).
  cores =
    with :unknown <- :erlang.system_info(:logical_processors_available),
         do: :erlang.system_info(:logical_processors)

  config :conduit, Conduit.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    # One pool of 4 connections per core, capped at 90 (Postgres allows 100). Postgres shares the cores, and many more
    # backends only make every statement slower (80 instead of 24 cost 14% more Postgres CPU per request); at the end
    # of 5-minute holds at 41,000 users, 32 instead of 24 took p95 488 -> 374 and 516 -> 489 ms in two batches.
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "#{min(4 * cores, 90)}"),
    # At saturation, let a query wait up to 200 ms for a connection (DBConnection's default is 50 ms) before the
    # pool starts shedding: latency has headroom under the 500 ms p95 limit, while every shed query is a 500.
    queue_target: 200,
    # Each connection reuses one generic plan per prepared statement. Postgres's default picks it after five runs
    # for every statement but the global and tag lists' ids queries, whose LIMIT parameter makes the generic plan's
    # cost estimate look worse than a custom plan for LIMIT 10, so it re-planned them on every call (0.09 and 0.15 ms,
    # ~7% of Postgres's statement time); their generic plans are the same backward index scans. Session-level, so
    # within the box's fixed server config.
    parameters: [plan_cache_mode: "force_generic_plan"]

  config :conduit, ConduitWeb.Endpoint,
    server: true,
    http: [
      ip: ip,
      port: String.to_integer(System.get_env("PORT", "3000")),
      # Responses go out uncompressed: gzip is optional in SPEC.md and costs CPU on every response, which the box,
      # shared with Postgres, is shorter of than bandwidth.
      http_options: [compress: false],
      # Collect each connection's garbage after every request (Bandit's default is every 5th), so a user who is
      # thinking between pages doesn't hold on to the heap their last request built.
      http_1_options: [gc_every_n_keepalive_requests: 1],
      thousand_island_options: [
        # Clients hold one keep-alive connection each and think for up to 70 s between pages; don't close them first.
        read_timeout: 75_000,
        # Every user connects directly, so allow bursts of new connections (the box's somaxconn is 65535).
        transport_options: [backlog: 8192],
        # Start each connection process with a 4,181-word (33 KB) heap. The GC after every request shrinks the heap
        # back to this minimum, and a request needs about this much, so it no longer re-grows the heap through a
        # series of minor collections on every request. Costs ~35 KB per connection (~1 GB at 27,000 users).
        genserver_options: [spawn_opt: [min_heap_size: 4181]]
      ]
    ]

  config :joken, default_signer: System.fetch_env!("JWT_SECRET")
end
