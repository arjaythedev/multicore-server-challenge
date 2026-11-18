defmodule Conduit.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Conduit.Jwt.init(System.fetch_env!("JWT_SECRET"))
    Conduit.Handler.init()
    Conduit.Util.init()

    # Postgres connections: reads and writes in separate pools (see Conduit.Db). Few read connections, so that reads
    # wait and batch (Conduit.Pg.Conn), but enough that Postgres can use several cores for them: ~5/8 of the cores
    # (5 of 8; measured locally at 160k users, Postgres CPU per request 0.093 / 0.096 / 0.100 ms with 5 / 6 / 8, and 4
    # capped reads at 4 backends). Without group commit (write_opts/0), every write is its own commit, which waits for
    # its WAL flush, so a connection does one commit per flush and commits on separate connections share flushes: 4
    # write connections capped writes at ~1,800/s (140k users: write p99 2.1 s while reads were fine); 8: 34 ms; 16:
    # 21 ms at 160k. With group commit, fewer connections make bigger groups: half the cores (4 of 8) measured best,
    # saturated on an aged DB (250k users, 5-minute holds: 60.9k vs 59.1k req/s, p95 594 vs 759 ms with 16).
    reads = env_int("DB_READ", max(2, div(cores() * 5 + 4, 8)))
    writes = env_int("DB_WRITE", max(4, div(cores(), 2)))

    if reads + writes > 95, do: raise("DB_READ + DB_WRITE must be at most 95")

    pg = pg_opts(System.fetch_env!("DATABASE_URL"))

    children =
      Conduit.Pg.child_specs(:read, reads, Map.merge(pg, gather_opts()), route_slack()) ++
        Conduit.Pg.child_specs(:write, writes, Map.merge(pg, write_opts())) ++
        plan_child() ++
        [
          # bcrypt in batches of up to 6 interleaved hashes: a batch leaves when full or after the window, one batch per
          # dirty CPU scheduler at once. SCHED_IDLE threads (BCRYPT_IDLE) starve on a saturated box: one batch per
          # BCRYPT_IDLE_WAIT_MS, so at 250k users ~60% of logins timed out (10 s).
          {Conduit.Bcrypt,
           workers: env_int("BCRYPT_WORKERS", :erlang.system_info(:dirty_cpu_schedulers)),
           window_ms: env_int("BCRYPT_WINDOW_MS", 150),
           lanes: env_int("BCRYPT_LANES", 6),
           idle: env_int("BCRYPT_IDLE", 0),
           idle_wait_ms: env_int("BCRYPT_IDLE_WAIT_MS", 1000)},
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

  # Read plans (Conduit.Plan): a plan leaves once its oldest read has waited PLAN_WINDOW_MS (or PLAN_MAX wait), at
  # most PLAN_DEPTH plans at once, each statement in chunks of at most PLAN_CHUNK keys (Conduit.Plan.run/4), the
  # responses rendered by the NIF's plan context (PLAN_NIF=0: by Conduit.Plan's Erlang path). The favorite counts of
  # the NIF's plans come from the count lane (Conduit.PlanCounts; PLAN_COUNTS=0: from plan_articles), each run
  # waiting PLAN_COUNTS_GATHER_MS for more plans. Measured at 175k users (README "Read plans"): gather 0 / 35 / 65 ms,
  # Postgres CPU per request 0.059 -> 0.059 / 0.057 / 0.054 ms, p95 67 -> 76 / 117 / 148 ms.
  defp plan_child do
    nif = System.get_env("PLAN_NIF", "1") != "0"
    counts = nif and System.get_env("PLAN_COUNTS", "1") != "0"

    if Conduit.Handler.plan_enabled?(),
      do:
        if(counts,
          do: [{Conduit.PlanCounts, gather: env_int("PLAN_COUNTS_GATHER_MS", 65)}],
          else: []
        ) ++
          [
            {Conduit.Plan,
             window: env_int("PLAN_WINDOW_MS", 30),
             max: env_int("PLAN_MAX", 2048),
             depth: env_int("PLAN_DEPTH", 8),
             chunk: env_int("PLAN_CHUNK", 128),
             nif: if(counts, do: :counts, else: nif)}
          ],
      else: []
  end

  # Group commit on write connections (Conduit.Pg.Conn): the favorites, follows and comments waiting on a connection
  # commit together. DB_WRITE_GATHER_MS: a write round waits until its oldest write has waited that long, so that
  # groups get bigger (fewer commits and WAL flushes), for that much latency on writes. Measured at 175k users
  # (DB_WRITE=4): WAL fsyncs per write 0.45 (off) -> 0.47 (group, no window) -> 0.34 / 0.27 / 0.21 (5 / 10 / 20 ms),
  # Postgres CPU per request 0.063 -> 0.061 -> 0.058 / 0.057 / 0.056 ms.
  defp write_opts do
    %{
      group: System.get_env("DB_WRITE_GROUP", "1") != "0",
      gather: env_int("DB_WRITE_GATHER_MS", 20)
    }
  end

  # Read connections: a round waits until its oldest request has waited DB_GATHER_MS, or
  # DB_GATHER_MAX requests are waiting, so that more reads share each batched execution (Conduit.Pg.Conn).
  defp gather_opts do
    %{gather: env_int("DB_GATHER_MS", 0), gather_max: env_int("DB_GATHER_MAX", 1024)}
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
