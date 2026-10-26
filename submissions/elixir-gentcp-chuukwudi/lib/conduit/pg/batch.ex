defmodule Conduit.PG.Batch do
  @moduledoc """
  Read batching, done by each read connection for the requests routed to it (Conduit.DB.read/2).

  Requests of the same kind (an article by slug, a page of the global list, a feed page, ...) wait in their kind's
  queue while the connection has a round in flight. When it completes, everything queued goes out as ONE round: one
  statement per kind (Conduit.SQL: the kind's query runs once per request over the unnested parameters of all of
  them), every statement pipelined under a single Sync. Each request gets its own rows as soon as its kind's
  statement completes.

  Most of a cheap statement's cost in Postgres is per statement and per round trip rather than per row (protocol
  messages, waking the backend, transaction start and commit), so a round shares the round trip and the implicit
  transaction between kinds, and a statement shares its executor start-up between requests. Each statement still
  takes its own snapshot, and each request's data is still read by its own execution of its query while the request
  is being served; nothing is shared between requests.

  There is no timer. At low load a round holds one request and nothing waits; under load requests queue while the
  round is in flight, so rounds grow by themselves exactly when per-statement overhead matters.
  """
  alias Conduit.PG.Proto

  @kinds [
    :tags,
    :user,
    :login,
    :profile,
    :article,
    :comments,
    :list_all,
    :list_tag,
    :list_author,
    :list_favorited,
    :list_feed
  ]
  @nkinds length(@kinds)

  def kinds, do: @kinds
  def nkinds, do: @nkinds
  def stmt_name(i), do: "r#{i}"

  for {k, i} <- Enum.with_index(@kinds) do
    def index(unquote(k)), do: unquote(i)
  end

  @doc "Per-kind constants: {statement names, layouts, result formats}, each a tuple indexed by kind."
  def spec(read_kinds) do
    layouts = Map.new(read_kinds, fn {k, layout, _sql} -> {index(k), layout} end)

    {List.to_tuple(for i <- 0..(@nkinds - 1), do: stmt_name(i)),
     List.to_tuple(for i <- 0..(@nkinds - 1), do: Map.fetch!(layouts, i)),
     List.to_tuple(for k <- @kinds, do: result_formats(k))}
  end

  # The tag list comes back as Postgres's text array literal, which becomes JSON with one C-level replace when no
  # name needs quoting (Conduit.JSON.pg_array_to_json); every other column is binary.
  defp result_formats(:tags), do: Proto.formats([1, 0])
  defp result_formats(_), do: Proto.formats([1])

  def empty_queues, do: Tuple.duplicate([], @nkinds)

  @doc """
  Everything queued as one round: {iodata (ending in Sync), [reqs tuple per statement, in order], empty queues}.
  Queues hold {pid, ref, args} newest first; at most `max` requests of a kind go per statement (the rest stay).
  """
  def round(queues, {names, layouts, formats}, max) do
    round(queues, names, layouts, formats, max, 0, [], [])
  end

  defp round(queues, _, _, _, _, @nkinds, data, batches),
    do: {[:lists.reverse(data), Proto.sync()], :lists.reverse(batches), queues}

  defp round(queues, names, layouts, formats, max, k, data, batches) do
    case elem(queues, k) do
      [] ->
        round(queues, names, layouts, formats, max, k + 1, data, batches)

      items ->
        {items, rest} = split_oldest(:lists.reverse(items), max)
        bind = Proto.bind_execute(elem(names, k), params(elem(layouts, k), items), elem(formats, k))
        reqs = List.to_tuple(for {pid, ref, _} <- items, do: {pid, ref})
        queues = put_elem(queues, k, rest)
        round(queues, names, layouts, formats, max, k + 1, [bind | data], [reqs | batches])
    end
  end

  # oldest-first list -> {first max, the rest back as newest-first}
  defp split_oldest(items, max) when length(items) <= max, do: {items, []}

  defp split_oldest(items, max) do
    {now, later} = Enum.split(items, max)
    {now, :lists.reverse(later)}
  end

  # ---------- parameter arrays per layout ----------

  defp params(:i, items), do: [Proto.array(:int4, idxs(items))]

  defp params(:iv, items), do: [Proto.array(:int4, idxs(items)), Proto.array(:int8, for({_, _, v} <- items, do: v))]

  defp params(:ik, items), do: [Proto.array(:int4, idxs(items)), Proto.array(:text, for({_, _, k} <- items, do: k))]

  defp params(:ivk, items) do
    [
      Proto.array(:int4, idxs(items)),
      Proto.array(:int8, for({_, _, {v, _}} <- items, do: v)),
      Proto.array(:text, for({_, _, {_, k}} <- items, do: k))
    ]
  end

  defp params(:ivlo, items) do
    [
      Proto.array(:int4, idxs(items)),
      Proto.array(:int8, for({_, _, {v, _, _}} <- items, do: v)),
      Proto.array(:int4, for({_, _, {_, l, _}} <- items, do: l)),
      Proto.array(:int8, for({_, _, {_, _, o}} <- items, do: o))
    ]
  end

  defp params(:ivlok, items) do
    [
      Proto.array(:int4, idxs(items)),
      Proto.array(:int8, for({_, _, {v, _, _, _}} <- items, do: v)),
      Proto.array(:int4, for({_, _, {_, l, _, _}} <- items, do: l)),
      Proto.array(:int8, for({_, _, {_, _, o, _}} <- items, do: o)),
      Proto.array(:text, for({_, _, {_, _, _, k}} <- items, do: k))
    ]
  end

  defp idxs(items), do: :lists.seq(0, length(items) - 1)
end
