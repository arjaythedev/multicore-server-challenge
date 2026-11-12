defmodule Conduit.Bcrypt do
  @moduledoc false
  # Cost-10 bcrypt for registration, login and password changes, on our own NIF (native/): Openwall's core, plus
  # interleaving of up to 4 independent hashes (from the rust-tokio-Scooter1337 submission). A Blowfish round is a
  # chain of dependent table loads, so one hash leaves most of a core idle; interleaved hashes fill it.
  #
  # Concurrent hashes meet in this process. A batch goes to a worker when 4 are waiting, or when the oldest has
  # waited BCRYPT_WINDOW_MS; at most BCRYPT_WORKERS batches run at once. Every hash still runs all of its 2^10
  # iterations with its own salt; nothing is reused between requests.
  #
  # By default a batch runs on a dirty CPU scheduler. With BCRYPT_IDLE=n it runs on one of n threads of the NIF's own
  # under SCHED_IDLE (after zig-iouring-nick-potts), so that it only takes CPU nothing else wants; if that hasn't
  # answered within BCRYPT_IDLE_WAIT_MS (the box is saturated), the batch is computed again on a dirty CPU scheduler
  # and the idle threads' late answer is dropped. Off by default: on a saturated box the idle threads get no CPU and
  # every batch waits out the fallback.

  alias Conduit.Bcrypt.Nif

  # the NIF's lane counts (all checked at startup); `lanes` (BCRYPT_LANES) is the batch size used
  @max_lanes 6
  @cost10 ["$2a$10$", "$2b$10$", "$2y$10$"]

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [self(), opts])

  @doc "A new hash of `password` (at most 72 bytes, no NUL) with a fresh random salt."
  def hash(password), do: run(password, Nif.salt(:crypto.strong_rand_bytes(16)))

  @doc "Whether `password` matches `stored`. Like bcrypt itself, only the first 72 bytes of the password count."
  def verify(password, stored) do
    password = if byte_size(password) > 72, do: binary_part(password, 0, 72), else: password

    cond do
      byte_size(stored) != 60 -> false
      String.starts_with?(stored, @cost10) -> matches?(run(password, stored), stored)
      # Another cost can't share a batch: computed alone, in this process (still on a dirty scheduler).
      true -> matches?(single(password, stored), stored)
    end
  end

  defp matches?({:ok, hash}, stored), do: :crypto.hash_equals(hash, stored)
  defp matches?(_, _), do: false

  defp single(password, setting) do
    case Nif.hash([password], [setting]) do
      [hash] -> {:ok, hash}
      :error -> :error
    end
  end

  defp run(password, setting) do
    ref = :erlang.monitor(:process, __MODULE__, [{:alias, :reply_demonitor}])
    send(__MODULE__, {:job, ref, password, setting, now()})

    receive do
      {^ref, result} -> result
      {:DOWN, ^ref, _, _, _} -> :error
    after
      30_000 ->
        :erlang.demonitor(ref, [:flush])
        :error
    end
  end

  # ------------------------------------------------------------------ the collector

  def init(parent, opts) do
    Process.register(self(), __MODULE__)
    opts = Keyword.put_new(opts, :lanes, @max_lanes)
    self_test!()
    idle = idle_start(Keyword.get(opts, :idle, 0))
    :proc_lib.init_ack(parent, {:ok, self()})

    s = %{
      q: :queue.new(),
      n: 0,
      busy: 0,
      timer: nil,
      workers: opts[:workers],
      window: opts[:window_ms],
      lanes: opts[:lanes],
      idle: idle,
      idle_wait: Keyword.get(opts, :idle_wait_ms, 1000)
    }

    loop(s)
  end

  defp loop(s) do
    receive do
      {:job, _, _, _, _} = job -> loop(dispatch(%{s | q: :queue.in(job, s.q), n: s.n + 1}))
      :tick -> loop(dispatch(%{s | timer: nil}))
      :done -> loop(dispatch(%{s | busy: s.busy - 1}))
    end
  end

  defp dispatch(%{n: 0} = s), do: s
  defp dispatch(%{busy: b, workers: w} = s) when b >= w, do: s

  defp dispatch(s) do
    {:value, {:job, _, _, _, oldest}} = :queue.peek(s.q)
    waited = now() - oldest

    if s.n >= s.lanes or waited >= s.window do
      {jobs, q} = take(s.q, min(s.n, s.lanes), [])
      batcher = self()

      %{idle: idle, idle_wait: idle_wait} = s

      spawn(fn ->
        compute(jobs, idle, idle_wait)
        send(batcher, :done)
      end)

      dispatch(%{s | q: q, n: s.n - length(jobs), busy: s.busy + 1})
    else
      timer = s.timer || Process.send_after(self(), :tick, s.window - waited)
      %{s | timer: timer}
    end
  end

  defp take(q, 0, acc), do: {:lists.reverse(acc), q}

  defp take(q, k, acc) do
    {{:value, job}, q} = :queue.out(q)
    take(q, k - 1, [job | acc])
  end

  # The threads are started once per VM (a restarted collector reuses them).
  defp idle_start(0), do: false

  defp idle_start(n) do
    case Nif.idle_start(n) do
      :ok ->
        true

      {:error, :started} ->
        true

      {:error, reason} ->
        IO.puts(
          :stderr,
          "bcrypt: no SCHED_IDLE threads (#{inspect(reason)}), dirty schedulers only"
        )

        false
    end
  end

  # Runs in a process of its own, which exits afterwards: a late answer from the idle threads is dropped with it.
  defp compute(jobs, idle, idle_wait) do
    keys = for {:job, _, key, _, _} <- jobs, do: key
    settings = for {:job, _, _, setting, _} <- jobs, do: setting

    case hashes(keys, settings, idle, idle_wait) do
      hashes when is_list(hashes) ->
        Enum.zip_with(jobs, hashes, fn {:job, to, _, _, _}, hash ->
          send(to, {to, {:ok, hash}})
        end)

      :error ->
        # one bad input fails the whole batch: each on its own
        for {:job, to, key, setting, _} <- jobs, do: send(to, {to, single(key, setting)})
    end
  end

  defp hashes(keys, settings, true, idle_wait) do
    ref = make_ref()

    case Nif.hash_idle(keys, settings, ref) do
      :ok ->
        receive do
          {^ref, result} -> result
        after
          idle_wait -> Nif.hash(keys, settings)
        end

      :error ->
        :error
    end
  end

  defp hashes(keys, settings, false, _), do: Nif.hash(keys, settings)

  defp now, do: System.monotonic_time(:millisecond)

  # Every lane count must give exactly the single-hash results (as rust-tokio-Scooter1337 checks at startup).
  defp self_test! do
    inputs = [
      {"batch self test", "$2a$04$abcdefghijklmnopqrstuu"},
      {"één 🙂", "$2b$04$......................"},
      {"", "$2y$04$abcdefghijklmnopqrstuu"},
      {String.duplicate("1234567890", 7) <> "12", "$2b$04$012345678901234567890u"},
      {"password123", "$2b$04$9.9.9.9.9.9.9.9.9.9.9u"},
      {"x", "$2a$04$zzzzzzzzzzzzzzzzzzzzzu"}
    ]

    serial = for {key, setting} <- inputs, do: Nif.hash([key], [setting])

    for n <- 2..@max_lanes do
      {keys, settings} = inputs |> Enum.take(n) |> Enum.unzip()
      batch = Nif.hash(keys, settings)

      if batch != Enum.map(Enum.take(serial, n), &hd/1),
        do: raise("bcrypt self-test failed for #{n} lanes: #{inspect(batch)}")
    end

    :ok
  end
end
