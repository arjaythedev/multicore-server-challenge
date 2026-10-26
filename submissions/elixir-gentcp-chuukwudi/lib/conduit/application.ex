defmodule Conduit.Application do
  @moduledoc false
  use Application
  alias Conduit.PG.{Batch, Conn}
  alias Conduit.{SQL, DB}

  def start(_type, _args) do
    cfg = config()
    Conduit.JSON.init()
    Conduit.JWT.init(cfg.secret)
    Conduit.Bcrypt.self_test!()

    app_sorts = app_sorts_tags?(cfg.db)
    :persistent_term.put(:conduit_app_sorts_tags, app_sorts)

    read_kinds = SQL.read_kinds(app_sorts)
    read_stmts = for {k, layout, sql} <- read_kinds, do: {Batch.stmt_name(Batch.index(k)), sql, SQL.oids(layout)}
    write_stmts = for {name, sql, oids} <- SQL.write_stmts(app_sorts), do: {Atom.to_string(name), sql, oids}
    load = DB.init(cfg.read_conns, cfg.write_conns)
    read_opts = %{spec: Batch.spec(read_kinds), batch_max: cfg.batch_max, load: load}

    children =
      for(i <- 0..(cfg.read_conns - 1), do: {Conn, {cfg.db, :read, read_stmts, i, read_opts}}) ++
        for(i <- 0..(cfg.write_conns - 1), do: {Conn, {cfg.db, :write, write_stmts, i, %{}}}) ++
        [
          {Conduit.Bcrypt, %{workers: cfg.bcrypt_workers, window: cfg.bcrypt_window}},
          {Conduit.HTTP, %{ip: cfg.ip, port: cfg.port, acceptors: cfg.acceptors, worker_heap: cfg.worker_heap}}
        ]

    IO.puts(
      "conduit: #{cfg.read_conns} read + #{cfg.write_conns} write connections, batch #{cfg.batch_max}, " <>
        "app-sorted tags #{app_sorts}, listening on #{:inet.ntoa(cfg.ip)}:#{cfg.port}"
    )

    Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 10_000, max_seconds: 10, name: Conduit.Sup)
  end

  # When the database collates text in byte order, the app can sort an article's few tag names itself (UTF-8 byte
  # order = code point order = what Postgres's ORDER BY name returns), saving a sort node per article in Postgres.
  defp app_sorts_tags?(db) do
    sock = Conn.connect!(db, 150)

    {:ok, [[collate, provider, locale]]} =
      Conn.simple_query(
        sock,
        "SELECT datcollate, datlocprovider::text, coalesce(datlocale, '') FROM pg_database " <>
          "WHERE datname = current_database()"
      )

    :gen_tcp.close(sock)
    bytewise = ["C", "POSIX", "C.UTF-8", "C.utf8"]

    case provider do
      "c" -> collate in bytewise
      "b" -> locale in bytewise
      _ -> false
    end
  end

  defp config do
    url = URI.parse(env!("DATABASE_URL"))
    [user, password] = String.split(url.userinfo || "", ":", parts: 2) |> Enum.map(&URI.decode/1) |> pad2()
    {:ok, ip} = :inet.parse_address(String.to_charlist(System.get_env("HOST", "0.0.0.0")))
    cores = System.schedulers_online()
    read_conns = int_env("READ_CONNS", 6)
    write_conns = int_env("WRITE_CONNS", 6)
    if read_conns + write_conns + 1 > 95, do: raise("too many Postgres connections (max 95)")

    %{
      db: %{
        host: url.host || "127.0.0.1",
        port: url.port || 5432,
        user: user,
        password: password,
        database: String.trim_leading(url.path || "/conduit", "/")
      },
      secret: env!("JWT_SECRET"),
      ip: ip,
      port: int_env("PORT", 3000),
      read_conns: read_conns,
      write_conns: write_conns,
      batch_max: int_env("BATCH_MAX", 64),
      bcrypt_workers: int_env("BCRYPT_WORKERS", max(1, div(cores, 4))),
      bcrypt_window: int_env("BCRYPT_WINDOW_MS", 200),
      acceptors: int_env("ACCEPTORS", 64),
      worker_heap: int_env("WORKER_HEAP", 4096)
    }
  end

  defp pad2([u]), do: [u, ""]
  defp pad2(l), do: l

  defp env!(k), do: System.get_env(k) || raise("#{k} is required")

  defp int_env(k, default) do
    case System.get_env(k) do
      nil -> default
      "" -> default
      v -> String.to_integer(v)
    end
  end
end
