defmodule Conduit.PlanCounts do
  @moduledoc false
  # The count lane (PLAN_COUNTS, after nish-std-amritk's count lane): read plans take their articles' favorite counts
  # out of plan_articles and ask this process for them. It runs one plan_counts statement at a time, over the union of
  # the article ids of every plan that asked while the previous one ran, each distinct article counted once. A count
  # walks the article's index entries (and the heap pages writes touched), so unlike the rest of an article it costs by
  # the row, and popular articles are on the pages of plan after plan.
  #
  # Not a cache: a run's ids are fixed when it is sent, after the requests they answer arrived, and nothing is kept
  # once its plans have their rows.

  @timeout 15_000

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [self(), opts])

  def init(parent, opts) do
    Process.register(self(), __MODULE__)
    :proc_lib.init_ack(parent, {:ok, self()})
    loop(Keyword.get(opts, :io, Conduit.Pg), Keyword.get(opts, :gather, 0))
  end

  @doc """
  Asks the lane for the favorite counts of `ids` (an encoded int8[] parameter): a handle for await/1, or nil when the
  lane isn't running.
  """
  def ask(ids) do
    case Process.whereis(__MODULE__) do
      nil ->
        nil

      pid ->
        ref = :erlang.monitor(:process, pid, [{:alias, :reply_demonitor}])
        send(pid, {:count, ref, ids})
        ref
    end
  end

  @doc "The answer to ask/1: `{:ok, plan_counts rows}` (raw, of a superset of the ids) or `:error`."
  def await(ref) do
    receive do
      {^ref, result} -> result
      {:DOWN, ^ref, _, _, _} -> :error
    after
      @timeout ->
        :erlang.demonitor(ref, [:flush])
        :error
    end
  end

  # `gather` (PLAN_COUNTS_GATHER_MS): a run waits until its first ask has waited that long, so that the next plans
  # join it.
  defp loop(io, gather) do
    receive do
      {:count, _, _} = ask ->
        run(take([ask], :erlang.monotonic_time(:millisecond) + gather), io)
    end

    loop(io, gather)
  end

  # every ask waiting, and those that come until `until`
  defp take(acc, until) do
    left = max(0, until - :erlang.monotonic_time(:millisecond))

    receive do
      {:count, _, _} = ask -> take([ask | acc], until)
    after
      left -> acc
    end
  end

  defp run(asks, io) do
    result =
      case io.await_raw(io.async(:read, [{:plan_counts, [union(asks)]}], :spread)) do
        {:ok, [rows]} -> {:ok, rows}
        _ -> :error
      end

    for {:count, ref, _} <- asks, do: send(ref, {ref, result})
  end

  # The asks' arrays as one (Postgres drops the duplicates).
  defp union(asks) do
    {n, elems} =
      Enum.reduce(asks, {0, []}, fn {:count, _, {:encoded, bin}}, {n, acc} ->
        case bin do
          <<_::32, 1::32, _::32, 20::32, k::32, 1::32, e::binary>> -> {n + k, [acc, e]}
          <<_::32, 0::32, _::binary>> -> {n, acc}
        end
      end)

    case n do
      0 ->
        {:encoded, <<12::32, 0::32, 0::32, 20::32>>}

      n ->
        {:encoded,
         IO.iodata_to_binary([<<20 + 12 * n::32, 1::32, 0::32, 20::32, n::32, 1::32>>, elems])}
    end
  end
end
