defmodule Conduit.DB do
  @moduledoc """
  The calls handlers make. `read/2` queues a request on a read connection, which batches it with others of its kind
  (Conduit.PG.Batch); `write/1` sends one request's statements (one Sync group, so one implicit transaction) to a
  write connection, round-robin. Both block the calling process until Postgres has answered (for writes:
  committed).

  A read goes to the less loaded of two neighbouring connections (a shared atomics counter per connection of
  requests queued or in flight): the power of two choices keeps queues even without any coordinating process.
  """
  alias Conduit.PG.{Batch, Proto}

  @timeout 20_000

  def read(kind, args) do
    {names, n, load, rr} = :persistent_term.get({__MODULE__, :read})
    i = rem(:atomics.add_get(rr, 1, 1), n)
    j = if i + 1 == n, do: 0, else: i + 1
    pick = if :atomics.get(load, i + 1) <= :atomics.get(load, j + 1), do: i, else: j
    :atomics.add(load, pick + 1, 1)
    ref = make_ref()

    try do
      send(elem(names, pick), {:r, Batch.index(kind), args, self(), ref})
    rescue
      ArgumentError ->
        :atomics.sub(load, pick + 1, 1)
        send(self(), {ref, {:error, %{code: "08006", message: "read connection restarting"}}})
    end

    receive do
      {^ref, res} -> res
    after
      @timeout -> {:error, %{code: "timeout", message: "read timed out"}}
    end
  end

  # stmts: [{name atom, [param iodata | nil]}]
  def write(stmts) do
    data = [for({name, params} <- stmts, do: Proto.bind_execute(Atom.to_string(name), params)), Proto.sync()]
    {names, counter} = :persistent_term.get({__MODULE__, :write})
    i = :atomics.add_get(counter, 1, 1)
    conn = elem(names, rem(i, tuple_size(names)))
    ref = make_ref()

    try do
      send(conn, {:q, data, self(), ref})
    rescue
      ArgumentError -> send(self(), {ref, {:error, %{code: "08006", message: "write connection restarting"}}})
    end

    receive do
      {^ref, res} -> res
    after
      @timeout -> {:error, %{code: "timeout", message: "write timed out"}}
    end
  end

  @doc "Connection names and counters; returns the read load counters (one slot per read connection)."
  def init(read_conns, write_conns) do
    reads = List.to_tuple(for i <- 0..(read_conns - 1), do: Conduit.PG.Conn.conn_name(:read, i))
    writes = List.to_tuple(for i <- 0..(write_conns - 1), do: Conduit.PG.Conn.conn_name(:write, i))
    load = :atomics.new(read_conns, signed: true)
    :persistent_term.put({__MODULE__, :read}, {reads, read_conns, load, :atomics.new(1, signed: false)})
    :persistent_term.put({__MODULE__, :write}, {writes, :atomics.new(1, signed: false)})
    load
  end
end
