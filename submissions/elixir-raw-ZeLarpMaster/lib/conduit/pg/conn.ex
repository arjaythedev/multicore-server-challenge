defmodule Conduit.Pg.Conn do
  @moduledoc false
  # One PostgreSQL connection = one process that owns the socket. At startup it authenticates and prepares every
  # statement in Conduit.Sql, plus a batched variant of each statement in Conduit.Sql.batchable/0.
  #
  # Requests are `{:q, reply_to, slot, items}`; the items of one request form one implicit transaction (one Sync).
  # Requests go out in rounds, at most `depth` rounds in flight (pipelining). With a round slot free, a request is
  # written at once. Otherwise it waits here, and when a round completes everything waiting goes out as the next round.
  # In a round, single-statement requests for the same batchable statement become one execution of its batched
  # variant: their parameters as arrays, one row set back, split by request ordinal (`r.i`). So batches form only
  # under load, and grow with it, with no timer.
  #
  # A batch that fails (one bad parameter fails the whole statement) is retried as separate requests.

  alias Conduit.Pg.{Proto, Scram}
  require Logger

  @sock_opts [
    :binary,
    active: false,
    packet: :raw,
    nodelay: true,
    keepalive: true,
    buffer: 262_144,
    recbuf: 262_144,
    sndbuf: 262_144
  ]

  # parameter type of a single statement -> element type of the batched variant's array parameter
  @array_elem %{20 => "int8", 23 => "int4", 21 => "int2", 25 => "text", 1043 => "varchar"}

  def child_spec({name, slot, counters, opts}) do
    %{
      id: name,
      start: {__MODULE__, :start_link, [name, slot, counters, opts]},
      restart: :permanent
    }
  end

  def start_link(name, slot, counters, opts),
    do: :proc_lib.start_link(__MODULE__, :init, [self(), name, slot, counters, opts])

  def init(parent, name, slot, counters, opts) do
    Process.register(self(), name)
    {sock, stmts, batches} = connect(opts, 0)
    :atomics.put(counters, slot, 0)
    :ok = :inet.setopts(sock, active: true)
    :proc_lib.init_ack(parent, {:ok, self()})

    loop(%{
      sock: sock,
      stmts: stmts,
      batches: if(Map.get(opts, :batch, true), do: batches, else: %{}),
      counters: counters,
      buf: <<>>,
      cur: nil,
      q: :queue.new(),
      held: [],
      inflight: 0,
      depth: Map.get(opts, :depth, 2)
    })
  end

  # ------------------------------------------------------------------ request loop

  # Messages strictly in arrival order (no selective receive: under load the mailbox holds socket data and requests
  # interleaved, and scanning it for one kind costs more the longer it gets).
  defp loop(s) do
    receive do
      {:tcp, _, data} -> loop(pump(recv(s, data)))
      {:q, _, _, _} = req -> loop(pump(%{s | held: [req | s.held]}))
      {:tcp_closed, _} -> exit(:pg_closed)
      {:tcp_error, _, reason} -> exit({:pg_tcp_error, reason})
    end
  end

  # Everything held goes out as one round, in one socket write, if a round slot is free.
  defp pump(%{held: []} = s), do: s
  defp pump(%{inflight: n, depth: d} = s) when n >= d, do: s

  defp pump(s) do
    entries = group(:lists.reverse(s.held), s.batches, [], %{})
    {io, s} = encode(entries, %{s | held: [], inflight: s.inflight + 1}, [])

    case :gen_tcp.send(s.sock, io) do
      :ok -> s
      {:error, reason} -> exit({:pg_send, reason})
    end
  end

  # -> [{:one, req} | {:many, id, [req]}]: batchable single-statement requests grouped by statement.
  defp group([{:q, _, _, [{id, _}]} = req | rest], batches, ones, many)
       when is_map_key(batches, id),
       do: group(rest, batches, ones, Map.update(many, id, [req], &[req | &1]))

  defp group([req | rest], batches, ones, many),
    do: group(rest, batches, [{:one, req} | ones], many)

  defp group([], _batches, ones, many) do
    Enum.reduce(many, :lists.reverse(ones), fn
      {_id, [req]}, acc -> [{:one, req} | acc]
      {id, reqs}, acc -> [{:many, id, :lists.reverse(reqs)} | acc]
    end)
  end

  defp encode([], s, io), do: {io, s}

  defp encode([entry | rest], s, io) do
    {msgs, pending} = entry(entry, s, rest == [])
    s = if s.cur == nil, do: %{s | cur: start(pending)}, else: %{s | q: :queue.in(pending, s.q)}
    encode(rest, s, [io, msgs, Proto.sync()])
  end

  defp entry({:one, {:q, to, slot, items}}, s, last?), do: one(to, slot, items, s, last?)

  defp entry({:one, {:q, to, slot, items, :nobatch}}, s, last?),
    do: one(to, slot, items, s, last?)

  defp entry({:many, id, reqs}, s, last?) do
    {name_z, param_oids, col_oids, arity} = Map.fetch!(s.batches, id)

    params =
      case arity do
        0 -> [length(reqs)]
        _ -> reqs |> Enum.map(fn {:q, _, _, [{_, p}]} -> p end) |> Enum.zip_with(& &1)
      end

    {Proto.bind_execute(name_z, param_oids, params), {{:many, reqs}, last?, [col_oids]}}
  end

  defp one(to, slot, items, s, last?) do
    {msgs, cols} = items(items, s.stmts, [], [])
    {msgs, {{:one, to, slot, items}, last?, cols}}
  end

  defp items([{id, params} | rest], stmts, io, cols) do
    {name_z, param_oids, col_oids} = Map.fetch!(stmts, id)
    items(rest, stmts, [io | Proto.bind_execute(name_z, param_oids, params)], [col_oids | cols])
  end

  defp items([], _stmts, io, cols), do: {io, :lists.reverse(cols)}

  # cur = {what to answer, last of its round?, column oids of the items still to complete, rows of the current
  # item, results so far, error}
  defp start({who, last?, cols}), do: {who, last?, cols, [], [], nil}

  defp recv(s, data) do
    buf = if s.buf == <<>>, do: data, else: <<s.buf::binary, data::binary>>
    messages(buf, s)
  end

  defp messages(<<t, len::32, rest::binary>> = buf, s) do
    blen = len - 4

    case rest do
      <<body::binary-size(^blen), tail::binary>> -> messages(tail, message(t, body, s))
      _ -> %{s | buf: buf}
    end
  end

  defp messages(buf, s), do: %{s | buf: buf}

  # DataRow: kept raw; the requester decodes it (Conduit.Pg.query/2), so this process only frames and routes.
  defp message(?D, <<_n::16, cols::binary>>, %{cur: {who, last?, left, rows, res, err}} = s),
    do: %{s | cur: {who, last?, left, [cols | rows], res, err}}

  # CommandComplete: the current item is done; its rows go with their column types
  defp message(?C, _body, %{cur: {who, last?, [oids | left], rows, res, err}} = s),
    do: %{s | cur: {who, last?, left, [], [{oids, :lists.reverse(rows)} | res], err}}

  # ErrorResponse: Postgres skips the rest of the request up to its Sync
  defp message(?E, body, %{cur: {who, last?, left, rows, res, _}} = s),
    do: %{s | cur: {who, last?, left, rows, res, {:pg, Map.get(Proto.error_fields(body), :code)}}}

  # ReadyForQuery: answer, move on to the next pending request
  defp message(?Z, _body, %{cur: {who, last?, _, _, res, err}} = s) do
    s = answer(who, :lists.reverse(res), err, s)
    s = if last?, do: %{s | inflight: s.inflight - 1}, else: s
    next(s)
  end

  # A FATAL error outside a request (e.g. the server shutting down): the socket closes next.
  defp message(?E, body, %{cur: nil} = s) do
    Logger.error("postgres: #{inspect(Proto.error_fields(body))}")
    s
  end

  # BindComplete, NoticeResponse, ParameterStatus, ...
  defp message(_t, _body, s), do: s

  defp next(s) do
    case :queue.out(s.q) do
      {{:value, pending}, q} -> %{s | cur: start(pending), q: q}
      {:empty, _} -> %{s | cur: nil}
    end
  end

  defp answer({:one, to, slot, _items}, res, err, s) do
    send(to, {to, if(err, do: {:error, err}, else: {:ok, res})})
    :atomics.sub(s.counters, slot, 1)
    s
  end

  # Every row starts with the request's ordinal `r.i` (int8, never NULL): route by it, strip it. Enum.group_by keeps
  # each request's rows in their order.
  defp answer({:many, reqs}, [{[_i | oids], rows}], nil, s) do
    by_i =
      Enum.group_by(rows, fn <<8::32, i::64-signed, _::binary>> -> i end, fn <<_::96,
                                                                               rest::binary>> ->
        rest
      end)

    Enum.reduce(reqs, 1, fn {:q, to, slot, _}, i ->
      send(to, {to, {:ok, [{oids, Map.get(by_i, i, [])}]}})
      :atomics.sub(s.counters, slot, 1)
      i + 1
    end)

    s
  end

  defp answer({:many, reqs}, _res, err, s) do
    Logger.warning("batch of #{length(reqs)} failed (#{inspect(err)}): retrying one by one")

    %{
      s
      | held:
          Enum.map(reqs, fn {:q, to, slot, items} -> {:q, to, slot, items, :nobatch} end) ++
            s.held
    }
  end

  # ------------------------------------------------------------------ startup

  # Postgres may still be starting (or restarting): retry for up to a minute.
  defp connect(opts, attempt) do
    with {:ok, sock} <- :gen_tcp.connect(opts.host, opts.port, @sock_opts, 10_000),
         {:ok, buf} <- handshake(sock, opts),
         {:ok, stmts, buf} <- prepare(sock, buf),
         {:ok, batches} <- prepare_batches(sock, buf, stmts) do
      {sock, stmts, batches}
    else
      {:error, reason} when attempt < 60 ->
        Logger.warning("postgres connect failed (#{inspect(reason)}), retrying")
        Process.sleep(1000)
        connect(opts, attempt + 1)

      {:error, reason} ->
        exit({:pg_connect, reason})
    end
  end

  defp handshake(sock, opts) do
    :ok = :gen_tcp.send(sock, Proto.startup(opts.user, opts.database, opts.params))
    auth(sock, <<>>, opts, nil)
  end

  defp auth(sock, buf, opts, scram) do
    case next(sock, buf) do
      {:ok, ?R, <<0::32>>, buf} ->
        ready(sock, buf)

      {:ok, ?R, <<3::32>>, buf} ->
        :ok = :gen_tcp.send(sock, Proto.password([opts.password, 0]))
        auth(sock, buf, opts, scram)

      {:ok, ?R, <<5::32, salt::binary-4>>, buf} ->
        inner = Base.encode16(:crypto.hash(:md5, [opts.password, opts.user]), case: :lower)
        md5 = "md5" <> Base.encode16(:crypto.hash(:md5, [inner, salt]), case: :lower)
        :ok = :gen_tcp.send(sock, Proto.password([md5, 0]))
        auth(sock, buf, opts, scram)

      {:ok, ?R, <<10::32, _mechanisms::binary>>, buf} ->
        {first, state} = Scram.client_first()
        :ok = :gen_tcp.send(sock, Proto.sasl_initial("SCRAM-SHA-256", first))
        auth(sock, buf, opts, state)

      {:ok, ?R, <<11::32, server_first::binary>>, buf} ->
        {final, server_sig} = Scram.client_final(server_first, opts.password, scram)
        :ok = :gen_tcp.send(sock, Proto.password(final))
        auth(sock, buf, opts, server_sig)

      {:ok, ?R, <<12::32, server_final::binary>>, buf} ->
        if Scram.verify_final(server_final, scram),
          do: auth(sock, buf, opts, nil),
          else: {:error, :bad_server_signature}

      {:ok, ?E, body, _} ->
        {:error, Proto.error_fields(body)}

      {:ok, _, _, buf} ->
        auth(sock, buf, opts, scram)

      error ->
        error
    end
  end

  defp ready(sock, buf) do
    case next(sock, buf) do
      {:ok, ?Z, _, buf} -> {:ok, buf}
      {:ok, ?E, body, _} -> {:error, Proto.error_fields(body)}
      {:ok, _, _, buf} -> ready(sock, buf)
      error -> error
    end
  end

  # Parse + Describe every statement, one Sync; record each one's parameter and result column type oids.
  defp prepare(sock, buf) do
    all = Conduit.Sql.all()

    :ok =
      :gen_tcp.send(sock, [
        for(
          {_id, name, sql} <- all,
          do: [Proto.parse(name, sql), Proto.describe_statement(name)]
        ),
        Proto.sync()
      ])

    described(sock, buf, all, %{}, nil)
  end

  defp described(sock, buf, all, acc, params) do
    case {next(sock, buf), all} do
      {{:ok, ?1, _, buf}, _} ->
        described(sock, buf, all, acc, params)

      {{:ok, ?t, body, buf}, _} ->
        described(sock, buf, all, acc, Proto.param_oids(body))

      {{:ok, ?T, body, buf}, [{id, name, _} | rest]} ->
        described(
          sock,
          buf,
          rest,
          Map.put(acc, id, {name <> <<0>>, params, Proto.column_oids(body)}),
          nil
        )

      {{:ok, ?n, _, buf}, [{id, name, _} | rest]} ->
        described(sock, buf, rest, Map.put(acc, id, {name <> <<0>>, params, []}), nil)

      {{:ok, ?Z, _, buf}, []} ->
        {:ok, acc, buf}

      {{:ok, ?E, body, _}, [{id, _, _} | _]} ->
        {:error, {:prepare, id, Proto.error_fields(body)}}

      {{:ok, _, _, buf}, _} ->
        described(sock, buf, all, acc, params)

      {error, _} ->
        error
    end
  end

  # The batched variant of each batchable statement, from its SQL and the parameter types Postgres reported for it.
  # Each one is prepared on its own Sync: one that Postgres rejects is logged and left unbatched.
  defp prepare_batches(sock, buf, stmts) do
    sqls = Map.new(Conduit.Sql.all(), fn {id, _, sql} -> {id, sql} end)

    Conduit.Sql.batchable()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, buf}, fn {id, i}, {:ok, acc, buf} ->
      {_, param_oids, _} = Map.fetch!(stmts, id)

      if Enum.all?(param_oids, &Map.has_key?(@array_elem, &1)) do
        name = "b#{i}"
        sql = Conduit.Sql.batched(id) || batch_sql(Map.fetch!(sqls, id), param_oids)

        :ok =
          :gen_tcp.send(sock, [
            Proto.parse(name, sql),
            Proto.describe_statement(name),
            Proto.sync()
          ])

        case described(sock, buf, [{id, name, sql}], %{}, nil) do
          {:ok, %{^id => {name_z, oids, cols}}, buf} ->
            {:cont, {:ok, Map.put(acc, id, {name_z, oids, cols, length(param_oids)}), buf}}

          {:error, {:prepare, ^id, fields}} ->
            Logger.warning("no batched #{id}: #{inspect(fields)}")
            {:cont, {:ok, acc, skip_to_ready(sock, buf)}}

          error ->
            {:halt, error}
        end
      else
        {:cont, {:ok, acc, buf}}
      end
    end)
    |> case do
      {:ok, batches, _buf} -> {:ok, batches}
      error -> error
    end
  end

  # The single statement, run once per element of its parameter arrays: `$k` becomes `r.pk`, and `r.i` (the
  # request's position) leads every row. Without parameters, the request count drives a series instead.
  defp batch_sql(sql, []) do
    "SELECT r.i, x.* FROM generate_series(1::int8, $1::int8) AS r(i) CROSS JOIN LATERAL (#{sql}) x"
  end

  defp batch_sql(sql, param_oids) do
    n = length(param_oids)

    arrays =
      param_oids
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {oid, k} -> "$#{k}::#{@array_elem[oid]}[]" end)

    cols = Enum.map_join(1..n, ", ", &"p#{&1}")
    inner = Regex.replace(~r/\$(\d+)/, sql, "r.p\\1")

    "SELECT r.i, x.* FROM unnest(#{arrays}) WITH ORDINALITY AS r(#{cols}, i) CROSS JOIN LATERAL (#{inner}) x"
  end

  defp skip_to_ready(sock, buf) do
    case next(sock, buf) do
      {:ok, ?Z, _, buf} -> buf
      {:ok, _, _, buf} -> skip_to_ready(sock, buf)
    end
  end

  # One backend message during startup (passive socket).
  defp next(_sock, <<t, len::32, rest::binary>>) when byte_size(rest) >= len - 4 do
    blen = len - 4
    <<body::binary-size(^blen), tail::binary>> = rest
    {:ok, t, body, tail}
  end

  defp next(sock, buf) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> next(sock, buf <> data)
      error -> error
    end
  end
end
