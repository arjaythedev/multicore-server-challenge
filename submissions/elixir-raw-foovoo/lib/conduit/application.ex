defmodule Conduit.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Conduit.Jwt.init(System.fetch_env!("JWT_SECRET"))
    Conduit.Handler.init()

    # Pool leases cover client-side work as well as PostgreSQL execution.
    pool = env_int("POOL", max(2, div(3 * cores(), 2)))

    if pool > 95, do: raise("POOL must be at most 95")

    pg = pg_opts(System.fetch_env!("DATABASE_URL"))

    children = [
      {Postgrex, [name: Conduit.Pg, pool_size: pool] ++ pg},
      {Conduit.Http,
       host: System.get_env("HOST", "0.0.0.0"),
       port: env_int("PORT", 3000),
       acceptors: env_int("ACCEPTORS", 16)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Conduit.Supervisor, max_restarts: 1000)
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

  # Session settings go in the startup packet: parallel workers and JIT only add latency to small OLTP statements.
  defp pg_opts(url) do
    uri = URI.parse(url)
    [user, pass] = String.split(uri.userinfo || "", ":", parts: 2) |> pad_pass()

    [
      hostname: uri.host || "127.0.0.1",
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/conduit", "/"),
      username: URI.decode_www_form(user),
      password: URI.decode_www_form(pass),
      types: Conduit.PgTypes,
      prepare: :named,
      parameters: [jit: "off", max_parallel_workers_per_gather: "0"],
      queue_target: 2_000,
      queue_interval: 5_000,
      timeout: 15_000,
      connect_timeout: 10_000,
      idle_interval: 30_000
    ]
  end

  defp pad_pass([user]), do: [user, ""]
  defp pad_pass(other), do: other
end
