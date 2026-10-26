defmodule Conduit.Bcrypt.Nif do
  @moduledoc false
  @on_load :load

  def load do
    path = :filename.join(:code.priv_dir(:conduit), ~c"bcrypt_nif")
    :erlang.load_nif(path, 0)
  end

  def hash_many(_jobs), do: :erlang.nif_error(:not_loaded)
  def gensalt(_random16), do: :erlang.nif_error(:not_loaded)
end

defmodule Conduit.Bcrypt do
  @moduledoc """
  bcrypt, cost 10, with a fresh random salt per hash and a full verify against the stored hash on every login.

  A Blowfish round is a chain of dependent table loads, so one hash leaves most of a core's execution units idle.
  The NIF runs up to four independent hashes interleaved round by round (same work per hash, better use of the
  core): measured 15 ms per hash four at a time against 52 ms alone. The coordinator here collects them: a hash
  that arrives when fewer than four are waiting waits up to `window` ms for company (logins are ~0.1% of requests,
  so the wait costs the percentiles nothing), and full batches go out at once. `workers` processes each run one
  batch at a time on a dirty CPU scheduler, which also bounds how many cores hashing can take from Postgres.
  """
  alias Conduit.Bcrypt.Nif

  @lanes 4

  def hash(password) do
    run(password, Nif.gensalt(:crypto.strong_rand_bytes(16)))
  end

  def verify(password, <<setting::binary-size(29), _::binary-size(31)>> = stored) do
    case run(password, setting) do
      {:ok, h} -> :crypto.hash_equals(h, stored)
      _ -> false
    end
  end

  def verify(_, _), do: false

  defp run(password, setting) do
    ref = make_ref()
    send(__MODULE__, {:job, {password, setting}, self(), ref})

    receive do
      {^ref, res} -> res
    after
      60_000 -> :error
    end
  end

  @doc "Every lane count must give exactly what the single-hash reference path gives."
  def self_test! do
    jobs = for i <- 1..4, do: {"pässwörd-#{i}" <> String.duplicate("x", i * 13), "$2b$04$" <> salt22(i)}
    single = Enum.flat_map(jobs, &Nif.hash_many([&1]))

    for n <- 2..4 do
      batched = Nif.hash_many(Enum.take(jobs, n))

      if batched != Enum.take(single, n) or Enum.any?(batched, &(&1 == :error)),
        do: raise("bcrypt self-test failed (#{n} lanes)")
    end

    # a known vector: "U*U" with this salt (OpenBSD/Openwall test vectors)
    [h] = Nif.hash_many([{"U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC."}])
    if h != "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", do: raise("bcrypt vector mismatch")
    :ok
  end

  defp salt22(i), do: binary_part(Nif.gensalt(:crypto.hash(:md5, <<i>>)), 7, 22)

  # ---------- coordinator ----------

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(%{workers: n, window: window}) do
    :proc_lib.start_link(__MODULE__, :init, [n, window], 5000, [{:message_queue_data, :off_heap}])
  end

  def init(n, window) do
    Process.register(self(), __MODULE__)
    me = self()
    workers = for _ <- 1..n, do: spawn_link(fn -> worker(me) end)
    :proc_lib.init_ack({:ok, self()})
    loop(%{q: :queue.new(), len: 0, idle: workers, timer: nil, due: false, window: window})
  end

  # Full batches of four go out as soon as a worker is idle. A partial batch waits for its window (started by its
  # first hash); once the window has passed it is `due` and goes to the next idle worker, whatever its size.
  defp loop(st) do
    receive do
      {:job, job, pid, ref} ->
        st = full(%{st | q: :queue.in({job, pid, ref}, st.q), len: st.len + 1})

        st =
          if st.len > 0 and st.timer == nil and not st.due,
            do: %{st | timer: Process.send_after(self(), :go, st.window)},
            else: st

        loop(st)

      :go ->
        loop(flush(%{st | timer: nil, due: true}))

      {:idle, w} ->
        st = %{st | idle: [w | st.idle]}
        loop(if st.due, do: flush(st), else: full(st))
    end
  end

  defp full(%{len: len, idle: [_ | _]} = st) when len >= @lanes, do: full(send_batch(st, @lanes))
  defp full(%{len: 0} = st), do: cancel(st)
  defp full(st), do: st

  defp flush(%{len: 0} = st), do: %{st | due: false}
  defp flush(%{idle: []} = st), do: st
  defp flush(st), do: flush(send_batch(st, min(st.len, @lanes)))

  defp send_batch(%{idle: [w | idle]} = st, n) do
    {batch, q} = take(st.q, n, [])
    send(w, {:run, batch})
    %{st | q: q, len: st.len - n, idle: idle}
  end

  defp cancel(%{timer: nil} = st), do: %{st | due: false}

  defp cancel(st) do
    Process.cancel_timer(st.timer)

    receive do
      :go -> :ok
    after
      0 -> :ok
    end

    %{st | timer: nil, due: false}
  end

  defp take(q, 0, acc), do: {:lists.reverse(acc), q}

  defp take(q, n, acc) do
    {{:value, x}, q} = :queue.out(q)
    take(q, n - 1, [x | acc])
  end

  defp worker(coord) do
    receive do
      {:run, batch} ->
        results =
          try do
            Nif.hash_many(for {job, _, _} <- batch, do: job)
          rescue
            _ -> Enum.map(batch, fn _ -> :error end)
          end

        Enum.zip_with(batch, results, fn {_, pid, ref}, r ->
          send(pid, {ref, if(is_binary(r), do: {:ok, r}, else: :error)})
        end)

        send(coord, {:idle, self()})
        worker(coord)
    end
  end
end
