defmodule Conduit.PG.Conn do
  @moduledoc """
  One Postgres connection, owned by one process. Statements are prepared at connect time; afterwards every query is
  a pre-encoded Bind/Execute.../Sync group written straight to the socket, and groups can be in flight back to back
  (pipelined): replies come back in order, so the process keeps a FIFO of who is waiting for which group.

  A read connection batches (Conduit.PG.Batch): requests `{:r, kind, args, pid, ref}` queue by kind while its round
  is in flight and all go out as the next round, one statement per kind under one Sync. Every row's first column is
  the request index; a statement's requests get their rows when its CommandComplete arrives. If a statement fails,
  Postgres skips the rest of the round: those requests get the error.

  A write connection runs `{:q, iodata, pid, ref}`: one request's own statement(s) (writes, and the reads that must
  share their transaction). The caller gets every row of the group at ReadyForQuery (after the commit), or the error.

  Replies are `{ref, {:ok, rows}}` or `{ref, {:error, %{code, message}}}`, where a row is the binary of its column
  values (the column count, and for batches the index column, stripped). Nothing is retained after a reply.
  """
  alias Conduit.PG.{Batch, Proto}

  def child_spec({cfg, role, stmts, idx, opts}) do
    %{id: {__MODULE__, role, idx}, start: {__MODULE__, :start_link, [cfg, role, stmts, idx, opts]}, restart: :permanent}
  end

  def start_link(cfg, role, stmts, idx, opts) do
    :proc_lib.start_link(__MODULE__, :init, [cfg, role, stmts, idx, opts], 30_000, [
      {:priority, :high},
      {:message_queue_data, :off_heap},
      {:fullsweep_after, 50}
    ])
  end

  def init(cfg, role, stmts, idx, opts) do
    Process.register(self(), conn_name(role, idx))
    sock = connect!(cfg, 50)
    prepare!(sock, stmts)
    :ok = :inet.setopts(sock, active: true)
    :proc_lib.init_ack({:ok, self()})

    loop(%{
      sock: sock,
      buf: <<>>,
      q: :queue.new(),
      acc: nil,
      cur: nil,
      err: nil,
      # read connections: queued requests by kind, whether a round is in flight, the load counter slot
      queues: Batch.empty_queues(),
      queued: 0,
      busy: false,
      spec: opts[:spec],
      batch_max: opts[:batch_max],
      load: opts[:load],
      slot: idx + 1
    })
  end

  def conn_name(:write, idx), do: :"pg_w#{idx}"
  def conn_name(:read, idx), do: :"pg_r#{idx}"

  # ---------- connect / authenticate / prepare (passive mode) ----------

  def connect!(cfg, tries) do
    case connect(cfg) do
      {:ok, sock} ->
        sock

      {:error, reason} when tries > 0 ->
        IO.puts(:stderr, "postgres connect failed: #{inspect(reason)}; retrying")
        Process.sleep(200)
        connect!(cfg, tries - 1)

      {:error, reason} ->
        exit({:postgres_connect, reason})
    end
  end

  def connect(cfg) do
    opts = [:binary, active: false, packet: :raw, nodelay: true, buffer: 262_144, recbuf: 262_144, sndbuf: 262_144]

    with {:ok, sock} <- :gen_tcp.connect(String.to_charlist(cfg.host), cfg.port, opts, 5000) do
      params = [
        {"user", cfg.user},
        {"database", cfg.database},
        {"client_encoding", "UTF8"},
        {"application_name", "conduit-elixir"},
        # Session settings only. Generic plans: every statement here plans the same for any parameters, so planning
        # is skipped on every execution. No JIT, no parallel workers, and no Memoize (so that no request in a batch
        # is ever handed a row another request's lookup fetched).
        {"plan_cache_mode", "force_generic_plan"},
        {"jit", "off"},
        {"max_parallel_workers_per_gather", "0"},
        {"enable_memoize", "off"},
        {"TimeZone", "UTC"}
      ]

      :ok = :gen_tcp.send(sock, Proto.startup(params))

      case auth(sock, cfg, <<>>, nil) do
        {:ok, _rest} -> {:ok, sock}
        {:error, _} = e -> e
      end
    end
  end

  defp auth(sock, cfg, buf, scram) do
    with {:ok, type, payload, buf} <- recv_msg(sock, buf) do
      case {type, payload} do
        {?R, <<0::32>>} ->
          auth(sock, cfg, buf, scram)

        {?R, <<3::32>>} ->
          :gen_tcp.send(sock, Proto.password(cfg.password))
          auth(sock, cfg, buf, scram)

        {?R, <<5::32, salt::binary-size(4)>>} ->
          :gen_tcp.send(sock, Proto.password(Proto.md5_password(cfg.user, cfg.password, salt)))
          auth(sock, cfg, buf, scram)

        {?R, <<10::32, _mechs::binary>>} ->
          {_nonce, bare, first} = Proto.scram_client_first()
          :gen_tcp.send(sock, Proto.sasl_initial(first))
          auth(sock, cfg, buf, {:first, bare})

        {?R, <<11::32, server_first::binary>>} ->
          {:first, bare} = scram
          {final, server_sig} = Proto.scram_client_final(cfg.password, bare, server_first)
          :gen_tcp.send(sock, final)
          auth(sock, cfg, buf, {:final, server_sig})

        {?R, <<12::32, "v=", sig::binary>>} ->
          {:final, server_sig} = scram
          if Base.decode64!(sig) == server_sig, do: auth(sock, cfg, buf, nil), else: {:error, :bad_server_signature}

        {?E, p} ->
          {:error, Proto.error_fields(p)}

        {?Z, _} ->
          {:ok, buf}

        _ ->
          auth(sock, cfg, buf, scram)
      end
    end
  end

  def recv_msg(sock, <<type, len::32, rest::binary>> = buf) do
    plen = len - 4

    case rest do
      <<payload::binary-size(plen), rest2::binary>> -> {:ok, type, payload, rest2}
      _ -> recv_more(sock, buf)
    end
  end

  def recv_msg(sock, buf), do: recv_more(sock, buf)

  defp recv_more(sock, buf) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, data} -> recv_msg(sock, buf <> data)
      {:error, _} = e -> e
    end
  end

  defp prepare!(sock, stmts) do
    msgs = for {name, sql, oids} <- stmts, do: Proto.parse(name, sql, oids)
    :ok = :gen_tcp.send(sock, [msgs, Proto.sync()])
    await_ready!(sock, <<>>, stmts)
  end

  defp await_ready!(sock, buf, stmts) do
    case recv_msg(sock, buf) do
      {:ok, ?Z, _, <<>>} ->
        :ok

      {:ok, ?E, p, _} ->
        err = Proto.error_fields(p)
        IO.puts(:stderr, "prepare failed: #{inspect(err)}")
        exit({:prepare_failed, err})

      {:ok, _, _, rest} ->
        await_ready!(sock, rest, stmts)

      {:error, e} ->
        exit({:prepare_failed, e})
    end
  end

  @doc "Simple-query protocol, text results (start-up checks only)."
  def simple_query(sock, sql) do
    :ok = :gen_tcp.send(sock, [?Q, <<byte_size(sql) + 5::32>>, sql, 0])
    collect_simple(sock, <<>>, [])
  end

  defp collect_simple(sock, buf, acc) do
    case recv_msg(sock, buf) do
      {:ok, ?D, <<n::16, cols::binary>>, rest} when is_list(acc) ->
        collect_simple(sock, rest, [text_cols(cols, n) | acc])

      {:ok, ?Z, _, _} ->
        if is_list(acc), do: {:ok, Enum.reverse(acc)}, else: acc

      {:ok, ?E, p, rest} ->
        collect_simple(sock, rest, {:error, Proto.error_fields(p)})

      {:ok, _, _, rest} ->
        collect_simple(sock, rest, acc)
    end
  end

  defp text_cols(_, 0), do: []

  defp text_cols(bin, n) do
    {v, rest} = Proto.text(bin)
    [v | text_cols(rest, n - 1)]
  end

  # ---------- the pipelined loop (active mode) ----------

  defp loop(st) do
    receive do
      {:tcp, _, data} ->
        buf = if st.buf == <<>>, do: data, else: st.buf <> data
        loop(parse(buf, st))

      {:r, k, args, pid, ref} ->
        st = %{st | queues: put_elem(st.queues, k, [{pid, ref, args} | elem(st.queues, k)]), queued: st.queued + 1}
        loop(if st.busy, do: st, else: next_round(st))

      {:q, data, pid, ref} ->
        send_or_die(st, data)
        loop(push(st, {:single, pid, ref}))

      {:inet_reply, _, :ok, _} ->
        loop(st)

      {:inet_reply, _, {:error, reason}, _} ->
        die(st, reason)

      {:inet_reply, _, _} ->
        loop(st)

      {:tcp_closed, _} ->
        die(st, :closed)

      {:tcp_error, _, reason} ->
        die(st, reason)
    end
  end

  # Straight to the port (Proto.write/2: no gen_tcp.send/2 lookup, monitor or wait); the driver's inet_reply comes
  # back as a message (dropped in loop/1), and a dead socket also arrives as tcp_closed.
  defp send_or_die(st, data) do
    Proto.write(st.sock, data)
  rescue
    ArgumentError -> die(st, :closed)
  end

  defp next_round(st) do
    {data, batches, queues} = Batch.round(st.queues, st.spec, st.batch_max)
    send_or_die(st, data)
    sent = Enum.reduce(batches, 0, &(tuple_size(&1) + &2))
    push(%{st | queues: queues, queued: st.queued - sent, busy: true}, {:round, batches})
  end

  defp push(%{acc: nil} = st, e), do: start(%{st | q: :queue.in(e, st.q)}, e)
  defp push(st, e), do: %{st | q: :queue.in(e, st.q)}

  # the head group starts receiving: a round collects into a map (index => rows) for its current batch
  defp start(st, {:round, batches}), do: %{st | acc: %{}, cur: batches}
  defp start(st, _), do: %{st | acc: [], cur: nil}

  # Fail everything in flight, then exit: the supervisor starts a fresh connection (which re-registers).
  defp die(st, reason) do
    err = %{code: "08006", message: "connection lost: #{inspect(reason)}"}

    case :queue.to_list(st.q) do
      [{:round, _} | rest] -> fail_batches(st.cur, err, st) && fail_all(rest, err, st)
      all -> fail_all(all, err, st)
    end

    queued = for kind <- Tuple.to_list(st.queues), {pid, ref, _} <- kind, do: {pid, ref}
    fail_batches([List.to_tuple(queued)], err, st)

    exit({:shutdown, {:postgres_connection_lost, reason}})
  end

  defp fail_all(entries, err, st) do
    for e <- entries do
      case e do
        {:round, batches} -> fail_batches(batches, err, st)
        {:single, pid, ref} -> send(pid, {ref, {:error, err}})
      end
    end
  end

  defp fail_batches(batches, err, st) do
    for reqs <- batches do
      if st.load, do: :atomics.sub(st.load, st.slot, tuple_size(reqs))
      for {pid, ref} <- Tuple.to_list(reqs), do: send(pid, {ref, {:error, err}})
    end

    true
  end

  defp parse(<<type, len::32, rest::binary>> = buf, st) do
    plen = len - 4

    case rest do
      <<payload::binary-size(plen), rest2::binary>> -> parse(rest2, handle(type, payload, st))
      _ -> %{st | buf: buf}
    end
  end

  defp parse(buf, st), do: %{st | buf: buf}

  # DataRow
  defp handle(?D, payload, %{acc: acc} = st) when is_map(acc) do
    <<_n::16, 4::32, idx::32, cols::binary>> = payload

    acc =
      case acc do
        %{^idx => rows} -> %{acc | idx => [cols | rows]}
        _ -> Map.put(acc, idx, [cols])
      end

    %{st | acc: acc}
  end

  defp handle(?D, <<_n::16, cols::binary>>, %{acc: acc} = st), do: %{st | acc: [cols | acc]}

  # CommandComplete in a round: that batch's rows are final (reads), so its requests get them now
  defp handle(?C, _, %{cur: [reqs | rest], err: nil} = st) do
    n = tuple_size(reqs)
    :atomics.sub(st.load, st.slot, n)
    reply_batch(reqs, st.acc, 0, n)
    %{st | cur: rest, acc: %{}}
  end

  # ReadyForQuery: the head group is complete
  defp handle(?Z, _, st) do
    {{:value, e}, q} = :queue.out(st.q)

    st =
      case e do
        {:round, _} ->
          if st.err, do: fail_batches(st.cur, st.err, st)
          %{st | busy: false}

        {:single, pid, ref} ->
          send(pid, {ref, if(st.err, do: {:error, st.err}, else: {:ok, :lists.reverse(st.acc)})})
          st
      end

    st = %{st | q: q, err: nil, acc: nil, cur: nil}

    st =
      case :queue.peek(q) do
        {:value, next} -> start(st, next)
        :empty -> st
      end

    if st.queued > 0 and not st.busy, do: next_round(st), else: st
  end

  defp handle(?E, payload, %{err: nil} = st), do: %{st | err: Proto.error_fields(payload)}
  # ParseComplete, BindComplete, CommandComplete of writes, NoData, NoticeResponse, ParameterStatus, ...
  defp handle(_, _, st), do: st

  defp reply_batch(_reqs, _acc, n, n), do: :ok

  defp reply_batch(reqs, acc, i, n) do
    {pid, ref} = elem(reqs, i)

    rows =
      case acc do
        %{^i => rows} -> :lists.reverse(rows)
        _ -> []
      end

    send(pid, {ref, {:ok, rows}})
    reply_batch(reqs, acc, i + 1, n)
  end
end
