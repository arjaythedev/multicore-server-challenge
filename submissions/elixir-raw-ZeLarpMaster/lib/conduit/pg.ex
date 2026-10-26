defmodule Conduit.Pg do
  @moduledoc false
  # Pools of Conduit.Pg.Conn processes. A caller picks the connection with the fewest requests in flight (an
  # :atomics counter per connection, incremented here and decremented by the connection when it answers), sends
  # it the request and waits for the answer on a monitor alias: no pool checkout, no extra process hop.

  @timeout 15_000

  @doc """
  Child specs for a pool of `size` connections; call once at startup, before the children start. `slack`: a
  single-statement request prefers its statement's connection while that one has at most `slack` more requests in
  flight than the least loaded (`nil`: always the least loaded).
  """
  def child_specs(pool, size, opts, slack \\ nil) do
    counters = :atomics.new(size, signed: true)
    names = List.to_tuple(for i <- 1..size, do: :"#{__MODULE__}.#{pool}.#{i}")
    :persistent_term.put({__MODULE__, pool}, {names, counters, size, slack})
    for i <- 1..size, do: {Conduit.Pg.Conn, {elem(names, i - 1), i, counters, opts}}
  end

  @doc "Runs `items` (`[{statement id, params}]`) as one implicit transaction: `{:ok, [rows per item]}` or `{:error, _}`."
  def query(pool, items) do
    case call(pool, items) do
      {:ok, res} -> {:ok, Enum.map(res, &decode/1)}
      error -> error
    end
  end

  @doc "As query/2, but each row is left as its raw DataRow column data (for Conduit.Render.Nif)."
  def query_raw(pool, items) do
    case call(pool, items) do
      {:ok, res} -> {:ok, Enum.map(res, &elem(&1, 1))}
      error -> error
    end
  end

  defp call(pool, items) do
    {names, counters, size, slack} = :persistent_term.get({__MODULE__, pool})
    slot = route(items, counters, size, slack)
    ref = :erlang.monitor(:process, elem(names, slot - 1), [{:alias, :reply_demonitor}])
    :atomics.add(counters, slot, 1)

    try do
      send(elem(names, slot - 1), {:q, ref, slot, items})
    rescue
      ArgumentError ->
        # not registered: the connection is restarting
        :atomics.sub(counters, slot, 1)
        :erlang.demonitor(ref, [:flush])
        {:error, :down}
    else
      _ ->
        receive do
          {^ref, result} -> result
          {:DOWN, ^ref, _, _, reason} -> {:error, {:down, reason}}
        after
          @timeout ->
            :erlang.demonitor(ref, [:flush])
            {:error, :timeout}
        end
    end
  end

  # Rows arrive raw from the connection: decoding here spreads that work over the requests' own processes.
  defp decode({oids, rows}), do: Enum.map(rows, &Conduit.Pg.Proto.decode_row(&1, oids))

  # Requests for the same statement that meet on one connection can share a batched execution (Conduit.Pg.Conn), so
  # a single-statement request goes to its statement's connection unless that one is clearly busier than the least
  # loaded (bounded affinity, after rust-tokio-Scooter1337's read routing).
  defp route([{id, _}], counters, size, slack) when is_integer(slack) do
    preferred = :erlang.phash2(id, size) + 1
    load = :atomics.get(counters, preferred)

    case pick(counters, size) do
      {_best, min} when load <= min + slack -> preferred
      {best, _min} -> best
    end
  end

  defp route(_items, counters, size, _slack), do: elem(pick(counters, size), 0)

  # Least loaded {slot, load}, scanning from a scheduler-dependent start so ties spread out.
  defp pick(counters, size) do
    first = rem(:erlang.system_info(:scheduler_id), size) + 1
    pick(counters, size, first, size - 1, first, :atomics.get(counters, first))
  end

  defp pick(_counters, _size, _i, _left, best, 0), do: {best, 0}
  defp pick(_counters, _size, _i, 0, best, v), do: {best, v}

  defp pick(counters, size, i, left, best, v) do
    i = if i == size, do: 1, else: i + 1
    w = :atomics.get(counters, i)

    if w < v,
      do: pick(counters, size, i, left - 1, i, w),
      else: pick(counters, size, i, left - 1, best, v)
  end
end
