defmodule Conduit.Bcrypt do
  @moduledoc false
  # Cost-10 bcrypt for registration, login and password changes, on our own NIF (native/): Openwall's core, plus
  # interleaving of up to 4 independent hashes (from the rust-tokio-Scooter1337 submission). A Blowfish round is a
  # chain of dependent table loads, so one hash leaves most of a core idle; interleaved hashes fill it.
  #
  # Concurrent hashes meet in this process. A batch goes to a worker when 4 are waiting, or when the oldest has
  # waited BCRYPT_WINDOW_MS; at most BCRYPT_WORKERS batches run at once (each on a dirty CPU scheduler). Every hash
  # still runs all of its 2^10 iterations with its own salt; nothing is reused between requests.

  alias Conduit.Bcrypt.Nif

  @lanes 4
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
    self_test!()
    :proc_lib.init_ack(parent, {:ok, self()})

    s = %{
      q: :queue.new(),
      n: 0,
      busy: 0,
      timer: nil,
      workers: opts[:workers],
      window: opts[:window_ms]
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

    if s.n >= @lanes or waited >= s.window do
      {jobs, q} = take(s.q, min(s.n, @lanes), [])
      batcher = self()

      spawn(fn ->
        compute(jobs)
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

  defp compute(jobs) do
    keys = for {:job, _, key, _, _} <- jobs, do: key
    settings = for {:job, _, _, setting, _} <- jobs, do: setting

    case Nif.hash(keys, settings) do
      hashes when is_list(hashes) ->
        Enum.zip_with(jobs, hashes, fn {:job, to, _, _, _}, hash ->
          send(to, {to, {:ok, hash}})
        end)

      :error ->
        # one bad input fails the whole batch: each on its own
        for {:job, to, key, setting, _} <- jobs, do: send(to, {to, single(key, setting)})
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Every lane count must give exactly the single-hash results (as rust-tokio-Scooter1337 checks at startup).
  defp self_test! do
    inputs = [
      {"batch self test", "$2a$04$abcdefghijklmnopqrstuu"},
      {"één 🙂", "$2b$04$......................"},
      {"", "$2y$04$abcdefghijklmnopqrstuu"},
      {String.duplicate("1234567890", 7) <> "12", "$2b$04$012345678901234567890u"}
    ]

    serial = for {key, setting} <- inputs, do: Nif.hash([key], [setting])

    for n <- 2..@lanes do
      {keys, settings} = inputs |> Enum.take(n) |> Enum.unzip()
      batch = Nif.hash(keys, settings)

      if batch != Enum.map(Enum.take(serial, n), &hd/1),
        do: raise("bcrypt self-test failed for #{n} lanes: #{inspect(batch)}")
    end

    :ok
  end
end
