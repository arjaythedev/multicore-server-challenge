defmodule Conduit.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Conduit.Jwt.init(System.fetch_env!("JWT_SECRET"))
    Conduit.Handler.init()

    # Postgres connections: reads and writes in separate pools (see Conduit.Db). Few read connections, so that reads
    # wait and batch (Conduit.Pg.Conn), but enough that Postgres can use several cores for them: ~5/8 of the cores
    # (5 of 8; measured locally at 160k users, Postgres CPU per request 0.093 / 0.096 / 0.100 ms with 5 / 6 / 8, and 4
    # capped reads at 4 backends). Writes don't batch: every one is its own commit, which waits for its WAL flush, so a
    # connection does one commit per flush and commits on separate connections share flushes. 4 write connections
    # capped writes at ~1,800/s (140k users: write p99 2.1 s while reads were fine); 8: 34 ms; 16: 21 ms at 160k.
    reads = env_int("DB_READ", max(2, div(cores() * 5 + 4, 8)))
    writes = env_int("DB_WRITE", max(4, cores() * 2))

    if reads + writes > 95, do: raise("DB_READ + DB_WRITE must be at most 95")

    pg = pg_opts(System.fetch_env!("DATABASE_URL"))

    children =
      Conduit.Pg.child_specs(:read, reads, pg, route_slack()) ++
        Conduit.Pg.child_specs(:write, writes, pg) ++
        [
          # bcrypt in batches of up to 4 interleaved hashes: a batch leaves when full or after the window
          {Conduit.Bcrypt,
           workers: env_int("BCRYPT_WORKERS", 1), window_ms: env_int("BCRYPT_WINDOW_MS", 150)},
          {Conduit.Http,
           host: System.get_env("HOST", "0.0.0.0"),
           port: env_int("PORT", 3000),
           acceptors: env_int("ACCEPTORS", 16)}
        ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Conduit.Supervisor,
      max_restarts: 1000
    )
  end

  # Cores this process may run on (respects the CPU affinity it was started with).
  defp cores do
    case :erlang.system_info(:logical_processors_available) do
      n when is_integer(n) -> n
      :unknown -> :erlang.system_info(:logical_processors_online)
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      v -> String.to_integer(v)
    end
  end

  # DB_ROUTE_SLACK: how much busier a read's preferred connection may be than the least loaded (Conduit.Pg); `off`
  # routes every read to the least loaded. Measured at 80k users: off 15.6% of reads batched, 0.138 ms Postgres CPU
  # per request; 2: 21.6%, 0.133 ms; 8: 30.7%, 0.123 ms (and p99 100 -> 57 ms at 120k).
  defp route_slack do
    case System.get_env("DB_ROUTE_SLACK", "8") do
      "off" -> nil
      v -> String.to_integer(v)
    end
  end

  # Session settings go in the startup packet: parallel workers and JIT only add latency to small OLTP statements.
  # Generic plans: every statement is planned once per connection instead of per execution (the plan cache kept
  # replanning the list statements, which cost as much as running them); measured -23% Postgres CPU per request.
  # PG_PARAMS adds more ("name=value,name=value") or overrides these, for experiments.
  defp pg_opts(url) do
    uri = URI.parse(url)
    [user, pass] = String.split(uri.userinfo || "", ":", parts: 2) |> pad_pass()

    extra =
      for kv <- String.split(System.get_env("PG_PARAMS", ""), ",", trim: true) do
        [k, v] = String.split(kv, "=", parts: 2)
        {k, v}
      end

    %{
      host: String.to_charlist(uri.host || "127.0.0.1"),
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/conduit", "/"),
      user: URI.decode_www_form(user),
      password: URI.decode_www_form(pass),
      # rounds in flight per connection, and whether waiting reads are batched (Conduit.Pg.Conn)
      depth: env_int("DB_DEPTH", 1),
      batch: System.get_env("DB_BATCH", "1") != "0",
      params:
        Enum.uniq_by(
          extra ++
            [
              {"jit", "off"},
              {"max_parallel_workers_per_gather", "0"},
              {"plan_cache_mode", "force_generic_plan"}
            ],
          &elem(&1, 0)
        )
    }
  end

  defp pad_pass([user]), do: [user, ""]
  defp pad_pass(other), do: other
end
