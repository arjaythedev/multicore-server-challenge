defmodule Conduit.Plan do
  @moduledoc false
  # Read plans: the article reads (the four lists, the feed, an article and its comments by slug) of every connection wait together
  # in one process for the next plan, which answers all of them in two rounds (the design of the top entries, see
  # README "Read plans"):
  #
  # - Phase A, one statement per kind of read present, over its DISTINCT keys (`Conduit.Sql` plan_*): each page's
  #   article ids and capped count, each slug's article id and body. Identical pages of different viewers are read
  #   once. Each kind goes out as its own request, so the kinds run on several connections at once.
  # - Phase B, one request: the columns of every distinct article of the plan, once (`plan_articles`), and the plan's
  #   viewers' favorites and follows among those articles and their authors (`plan_favs`, `plan_follows`).
  #
  # Each distinct article (and comment) is then rendered to JSON once per plan, around its viewer-dependent booleans
  # (Conduit.Render.Nif.article_parts/2, from a row laid out as its single statement's), and each response is an
  # iolist of those pieces with its viewer's booleans: byte for byte what rendering its single statement's rows
  # gives. Nothing outlives its plan: a plan takes only requests already waiting, and every value is read from
  # Postgres while they wait.
  #
  # The plan process only gathers: a plan leaves when its oldest request has waited `window` ms (or `max` wait),
  # with at most `depth` plans running, each in a process of its own. Anything unexpected (a failed statement, an
  # article deleted between the phases, a crash) answers `:fallback`, and that request runs its single statement.
  #
  # Tags and profiles (PLAN_SMALL) wait for plans too: each plan reads the tag list once for all of its tags requests,
  # and its profiles together (`plan_profile`), in a process of their own, so they don't wait for the article reads.

  require Logger
  alias Conduit.Pg
  alias Conduit.Pg.Proto
  alias Conduit.Render.Nif, as: Render

  @kinds [:list_all, :list_tag, :list_author, :list_favorited, :feed, :article_by_slug, :comments]
  @timeout 15_000

  @doc "The kinds of reads plans answer."
  def kinds, do: @kinds

  @doc """
  The response body of a read of `kind` (Conduit.Handler's parameters for its single statement), read through the
  next plan; nil when the article (comments) or user (profile) doesn't exist.
  """
  def body(kind, params) do
    case Process.whereis(__MODULE__) do
      nil ->
        single(kind, params)

      pid ->
        ref = :erlang.monitor(:process, pid, [{:alias, :reply_demonitor}])
        send(pid, {:plan, ref, kind, params})

        receive do
          {^ref, {:ok, body}} ->
            body

          {^ref, :fallback} ->
            single(kind, params)

          {:DOWN, ^ref, _, _, _} ->
            single(kind, params)
        after
          @timeout ->
            :erlang.demonitor(ref, [:flush])
            throw({:db_down, :timeout})
        end
    end
  end

  # the same body from the single statement
  defp single(:tags, _params) do
    [row] = Conduit.Db.read_raw(:tags, [])
    Render.tags(row)
  end

  defp single(:profile, params) do
    case Conduit.Db.read_raw(:profile, params) do
      [row] -> Render.profile(row)
      [] -> nil
    end
  end

  defp single(kind, params) do
    rows = Conduit.Db.read_raw(kind, params)

    case {kind, rows} do
      {:article_by_slug, [row]} -> Render.article(row)
      {:article_by_slug, _} -> nil
      {:comments, []} -> nil
      {:comments, rows} -> Render.comments(rows)
      {_list, rows} -> Render.list(rows)
    end
  end

  # ------------------------------------------------------------------ the plan process

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [self(), opts])

  def init(parent, opts) do
    Process.register(self(), __MODULE__)
    :proc_lib.init_ack(parent, {:ok, self()})

    loop(%{
      held: [],
      n: 0,
      since: 0,
      timer: false,
      running: %{},
      window: Keyword.fetch!(opts, :window),
      max: Keyword.fetch!(opts, :max),
      depth: Keyword.fetch!(opts, :depth),
      chunk: Keyword.fetch!(opts, :chunk),
      nif: Keyword.get(opts, :nif, true)
    })
  end

  defp loop(s) do
    receive do
      {:plan, _, _, _} = req -> loop(pump(hold(s, req)))
      :tick -> loop(pump(%{s | timer: false}))
      {:DOWN, mref, :process, _, reason} -> loop(pump(finished(s, mref, reason)))
    end
  end

  defp hold(%{held: []} = s, req),
    do: %{s | held: [req], n: 1, since: :erlang.monotonic_time(:millisecond)}

  defp hold(s, req), do: %{s | held: [req | s.held], n: s.n + 1}

  defp pump(%{held: []} = s), do: s
  defp pump(%{running: r, depth: d} = s) when map_size(r) >= d, do: s

  defp pump(%{window: w, n: n, max: max} = s) when w > 0 and n < max do
    left = s.since + w - :erlang.monotonic_time(:millisecond)

    cond do
      left <= 0 ->
        start(s)

      s.timer ->
        s

      true ->
        :erlang.send_after(left, self(), :tick)
        %{s | timer: true}
    end
  end

  defp pump(s), do: start(s)

  # At most `max` per plan, oldest first: a backlog becomes several plans, not one that only grows.
  defp start(%{n: n, max: max} = s) when n > max do
    {reqs, rest} = Enum.split(:lists.reverse(s.held), max)
    s = spawn_plan(s, reqs)
    # what is left has waited already
    %{
      s
      | held: :lists.reverse(rest),
        n: n - max,
        since: :erlang.monotonic_time(:millisecond) - s.window
    }
  end

  defp start(s), do: %{spawn_plan(s, :lists.reverse(s.held)) | held: [], n: 0}

  defp spawn_plan(s, reqs) do
    %{chunk: chunk, nif: nif} = s
    {_pid, mref} = spawn_monitor(fn -> run(reqs, chunk, nif) end)
    %{s | running: Map.put(s.running, mref, reqs)}
  end

  # Requests already answered ignore the fallback: their alias is gone after the first reply.
  defp finished(s, mref, reason) do
    {reqs, running} = Map.pop(s.running, mref, [])

    if reason != :normal do
      Logger.warning("plan of #{length(reqs)} failed: #{inspect(reason)}")
      for {:plan, ref, _, _} <- reqs, do: send(ref, {ref, :fallback})
    end

    %{s | running: running}
  end

  # ------------------------------------------------------------------ one plan

  @doc false
  # Every statement goes out in chunks of at most `chunk` keys (feeds: an eighth), each to the least loaded read
  # connection, so a plan's work spreads over several backends instead of one per kind. `nif`: the responses come
  # from Conduit.Render.Nif's plan context (PLAN_NIF=1, run_nif/4; `:counts`: with the favorite counts from
  # Conduit.PlanCounts when it runs, PLAN_COUNTS=1), or from the Erlang path below (PLAN_NIF=0, the reference it is
  # checked against). `io`: Conduit.Pg, or a stand-in for tests.
  def run(reqs, chunk, nif, io \\ Pg) do
    case Enum.split_with(reqs, fn {:plan, _, kind, _} -> kind in [:tags, :profile] end) do
      {[], reqs} ->
        run_articles(reqs, chunk, nif, io)

      {small, []} ->
        run_small(small, chunk, io)

      {small, reqs} ->
        # answered while the article reads are still in their first phase (a crash here takes the plan down, and
        # the plan process falls back for everything unanswered)
        spawn_link(fn -> run_small(small, chunk, io) end)
        run_articles(reqs, chunk, nif, io)
    end
  end

  defp run_articles([], _chunk, _nif, _io), do: :ok
  defp run_articles(reqs, chunk, true, io), do: run_nif(reqs, chunk, false, io)
  defp run_articles(reqs, chunk, :counts, io), do: run_nif(reqs, chunk, true, io)

  defp run_articles(reqs, chunk, false, io) do
    by_kind = Enum.group_by(reqs, fn {:plan, _, kind, _} -> kind end)

    # Phase A: distinct keys per kind, all chunks of all kinds in flight at once.
    keys =
      for {kind, rs} <- by_kind,
          do: {kind, rs |> Enum.map(fn {:plan, _, _, p} -> key(kind, p) end) |> Enum.uniq()}

    sent = send_a(keys, chunk, io)

    # kind -> %{key => value} or :error (when any of its chunks failed)
    res =
      Enum.reduce(sent, Map.new(by_kind, fn {kind, _} -> {kind, %{}} end), fn {kind, part, _base,
                                                                               handle},
                                                                              acc ->
        case {io.await_raw(handle), acc[kind]} do
          {{:ok, [rows]}, %{} = got} ->
            keys = List.to_tuple(part)

            Map.put(
              acc,
              kind,
              Enum.reduce(a_rows(kind, rows), got, fn {i, v}, got ->
                Map.put(got, elem(keys, i - 1), v)
              end)
            )

          _ ->
            Map.put(acc, kind, :error)
        end
      end)

    ok = for {kind, %{} = got} <- res, do: {kind, got}

    ids = for {kind, got} <- ok, {_, v} <- got, id <- a_ids(kind, v), uniq: true, do: id

    viewers =
      for {kind, %{}} <- ok, {:plan, _, _, [v | _]} <- by_kind[kind], v != 0, uniq: true, do: v

    users =
      for {:comments, got} <- ok,
          {_, cs} <- got,
          {author, _pieces} <- cs,
          uniq: true,
          do: author

    b = phase_b(ids, users, viewers, chunk, io)
    pieces = if b == :error, do: :error, else: pieces(ok, b)

    for {kind, rs} <- by_kind, {:plan, ref, _, params} <- rs do
      answer =
        with %{} = got <- res[kind],
             {_, favs, follows} <- b,
             %{} <- pieces do
          body(kind, params, Map.get(got, key(kind, params)), pieces, favs, follows)
        else
          _ -> :fallback
        end

      send(ref, {ref, if(answer == :fallback, do: :fallback, else: {:ok, answer})})
    end

    :ok
  end

  # Phase A's chunks, sent: [{kind, its keys, base (the slot of its first key), handle}]. Feeds first find the plan's
  # heavy shared followees (plan_feed_heavy), sent before everything else; the feed chunks go out once that answers
  # (without it, each feed counts its own).
  defp send_a(keys, chunk, io) do
    heavy =
      case List.keyfind(keys, :feed, 0) do
        {:feed, feeds} ->
          viewers = feeds |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
          io.async(:read, [{:plan_feed_heavy, [viewers]}], :spread)

        nil ->
          nil
      end

    sent =
      for {kind, ks} <- keys, kind != :feed, {part, base} <- parts(ks, chunk(kind, chunk)) do
        {kind, part, base, io.async(:read, [{stmt(kind), columns(kind, part)}], :spread)}
      end

    case heavy do
      nil ->
        sent

      handle ->
        heavy_ids =
          case io.await_raw(handle) do
            {:ok, [rows]} -> for <<8::32, f::64-signed>> <- rows, do: f
            _ -> []
          end

        heavy_param = Proto.encode_param(Proto.int8_array(), heavy_ids)
        {:feed, feeds} = List.keyfind(keys, :feed, 0)

        sent ++
          for {part, base} <- parts(feeds, chunk(:feed, chunk)) do
            {:feed, part, base,
             io.async(:read, [{:plan_feed, columns(:feed, part) ++ [heavy_param]}], :spread)}
          end
    end
  end

  # ------------------------------------------------------------------ the plan's small reads
  # The tags list is read and rendered once per plan, for every tags request in it. Profiles go out together as
  # plan_profile in chunks (rows by ordinal; no row: unknown user). Anything that fails falls back.
  defp run_small(small, chunk, io) do
    tags = for {:plan, ref, :tags, _} <- small, do: ref
    profiles = for {:plan, ref, :profile, [v, u]} <- small, do: {ref, v, u}
    tags_handle = if tags != [], do: io.async(:read, [{:tags, []}], :spread)

    profile_handles =
      for part <- Enum.chunk_every(profiles, chunk) do
        {vs, us} = part |> Enum.map(fn {_, v, u} -> {v, u} end) |> Enum.unzip()
        {part, io.async(:read, [{:plan_profile, [vs, us]}], :spread)}
      end

    try do
      if tags_handle do
        case io.await_raw(tags_handle) do
          {:ok, [[row]]} ->
            answer = {:ok, Render.tags(row)}
            for ref <- tags, do: send(ref, {ref, answer})

          _ ->
            for ref <- tags, do: send(ref, {ref, :fallback})
        end
      end

      for {part, handle} <- profile_handles do
        case io.await_raw(handle) do
          {:ok, [rows]} ->
            by_i = Map.new(rows, fn <<8::32, i::64-signed, row::binary>> -> {i, row} end)

            Enum.reduce(part, 1, fn {ref, _, _}, i ->
              case by_i do
                %{^i => row} -> send(ref, {ref, {:ok, Render.profile(row)}})
                _ -> send(ref, {ref, {:ok, nil}})
              end

              i + 1
            end)

          _ ->
            for {ref, _, _} <- part, do: send(ref, {ref, :fallback})
        end
      end
    catch
      kind, reason ->
        Logger.warning("plan's small reads failed: #{inspect({kind, reason})}")
        for {:plan, ref, _, _} <- small, do: send(ref, {ref, :fallback})
    end

    :ok
  end

  defp parts(keys, size),
    do: keys |> Enum.chunk_every(size) |> Enum.with_index(fn part, i -> {part, i * size} end)

  # ------------------------------------------------------------------ one plan, rendered by the NIF

  # As run/4's Erlang path, but the raw rows go into a Conduit.Render.Nif plan context as each chunk answers, which
  # renders every article and comment once and gives back each request's finished body; this process only routes.
  defp run_nif(reqs, chunk, counts, io) do
    plan = Render.plan_new()

    # each request as {ref, kind code, slot, viewer}: its key's index among its kind's distinct keys
    {tagged, kinds} = Enum.map_reduce(reqs, %{}, &slot/2)
    keys = for {kind, {_n, _slots, rev}} <- kinds, do: {kind, :lists.reverse(rev)}

    # kind codes of which a chunk failed: their requests fall back
    failed =
      Enum.reduce(send_a(keys, chunk, io), %{}, fn {kind, _part, base, handle}, failed ->
        case io.await_raw(handle) do
          {:ok, [rows]} ->
            :ok = Render.plan_add(plan, code(kind), base, rows)
            failed

          _ ->
            Map.put(failed, code(kind), true)
        end
      end)

    viewers = for {_, k, _, v} <- tagged, v != 0, not is_map_key(failed, k), uniq: true, do: v

    case nif_phase_b(plan, viewers, chunk, counts, io) do
      :ok when failed == %{} ->
        reply(plan, tagged)

      :ok ->
        {direct, planned} = Enum.split_with(tagged, fn {_, k, _, _} -> is_map_key(failed, k) end)
        fall_back(direct)
        reply(plan, planned)

      :error ->
        fall_back(tagged)
    end

    :ok
  end

  defp slot({:plan, ref, kind, [v | _] = params}, acc) do
    key = key(kind, params)
    code = code(kind)

    case acc do
      %{^kind => {n, slots, keys}} ->
        case slots do
          %{^key => slot} -> {{ref, code, slot, v}, acc}
          _ -> {{ref, code, n, v}, %{acc | kind => {n + 1, Map.put(slots, key, n), [key | keys]}}}
        end

      _ ->
        {{ref, code, 0, v}, Map.put(acc, kind, {1, %{key => 0}, [key]})}
    end
  end

  # Phase B as phase_b/5, each chunk's rows added to the plan as it answers: :ok or :error. `counts`: the favorite
  # counts come from the count lane, asked beside the articles, and go into the plan before them.
  defp nif_phase_b(plan, viewers, chunk, counts, io) do
    {all_ids, id_parts} = Render.plan_ids(plan, chunk)
    viewer_parts = if viewers == [], do: [], else: Enum.chunk_every(viewers, chunk)
    lane = if counts and id_parts != [], do: Conduit.PlanCounts.ask(all_ids)
    stmt = if lane, do: :plan_articles_nc, else: :plan_articles
    arts = send_all(for(part <- id_parts, do: {stmt, [part]}), io)

    favs =
      if id_parts == [] or viewer_parts == [],
        do: [],
        else: send_all(for(part <- viewer_parts, do: {:plan_favs, [part, all_ids]}), io)

    with :ok <- add_counts(plan, lane, arts, io),
         :ok <- add_all(plan, 7, arts, io) do
      {n, authors} = Render.plan_authors(plan)

      follows =
        if n == 0 or viewer_parts == [],
          do: [],
          else: send_all(for(part <- viewer_parts, do: {:plan_follows, [part, authors]}), io)

      with :ok <- add_all(plan, 8, favs, io), do: add_all(plan, 9, follows, io)
    end
  end

  defp add_counts(_plan, nil, _arts, _io), do: :ok

  defp add_counts(plan, lane, arts, io) do
    case Conduit.PlanCounts.await(lane) do
      {:ok, rows} ->
        Render.plan_add(plan, 10, 0, rows)

      :error ->
        _ = await_all(arts, io)
        :error
    end
  end

  # each handle's rows added to `table`, or :error (all are awaited either way)
  defp add_all(plan, table, handles, io) do
    Enum.reduce(handles, :ok, fn handle, status ->
      case io.await_raw(handle) do
        {:ok, [rows]} when status == :ok -> Render.plan_add(plan, table, 0, rows)
        _ -> :error
      end
    end)
  end

  @reply_batch 64

  # The answers, a batch per NIF call (each call stays short).
  defp reply(_plan, []), do: :ok

  defp reply(plan, tagged) do
    {batch, rest} = Enum.split(tagged, @reply_batch)
    for {ref, _} = msg <- Render.plan_bodies(plan, batch), do: send(ref, msg)
    reply(plan, rest)
  end

  defp fall_back(tagged), do: for({ref, _, _, _} <- tagged, do: send(ref, {ref, :fallback}))

  # the NIF's table of each kind
  defp code(:list_all), do: 0
  defp code(:list_tag), do: 1
  defp code(:list_author), do: 2
  defp code(:list_favorited), do: 3
  defp code(:feed), do: 4
  defp code(:article_by_slug), do: 5
  defp code(:comments), do: 6

  defp chunk(:feed, chunk), do: max(1, div(chunk, 8))
  defp chunk(_kind, chunk), do: chunk

  defp stmt(:list_all), do: :plan_all
  defp stmt(:list_tag), do: :plan_tag
  defp stmt(:list_author), do: :plan_author
  defp stmt(:list_favorited), do: :plan_favorited
  defp stmt(:feed), do: :plan_feed
  defp stmt(:article_by_slug), do: :plan_slug
  defp stmt(:comments), do: :plan_comments

  # The handler's parameters ([viewer | ...], as for the single statements) -> what the page depends on.
  defp key(:list_all, [_v, l, o]), do: {l, o}
  defp key(:feed, [v, l, o, d]), do: {v, l, o, d}
  defp key(:article_by_slug, [_v, slug]), do: {slug}
  defp key(:comments, [_v, slug]), do: {slug}
  defp key(_list, [_v, l, o, k]), do: {k, l, o}

  # distinct keys -> one array parameter per key position
  defp columns(_kind, keys), do: keys |> Enum.map(&Tuple.to_list/1) |> Enum.zip_with(& &1)

  # Phase A rows by ordinal. A comments thread is its comments in order, each rendered (Render.plan_comment/1) to
  # {author id, {a, c}}, or [:none] for none.
  defp a_rows(:comments, rows) do
    rows
    |> Enum.map(&Render.plan_comment/1)
    |> Enum.group_by(&elem(&1, 0), fn
      {_, :none} -> :none
      {_, author, pieces} -> {author, pieces}
    end)
  end

  defp a_rows(kind, rows), do: Map.new(rows, &a_row(kind, &1))

  # Phase A rows: ordinal first, then {count column (raw), page ids} or {article id, body column (raw)}.
  defp a_row(:article_by_slug, <<8::32, i::64-signed, 8::32, id::64-signed, body::binary>>),
    do: {i, {id, body}}

  defp a_row(_list, <<8::32, i::64-signed, 8::32, n::64-signed, arr::binary>>),
    do: {i, {n, int8_array(arr)}}

  defp a_ids(:article_by_slug, {id, _body}), do: [id]
  defp a_ids(:comments, _thread), do: []
  defp a_ids(_list, {_n, ids}), do: ids

  defp int8_array(<<_len::32, 0::32, _::binary>>), do: []

  defp int8_array(<<_len::32, 1::32, _flags::32, 20::32, _n::32, _lb::32, elems::binary>>),
    do: for(<<8::32, id::64-signed <- elems>>, do: id)

  # Phase B -> {articles: id -> {author id, list pieces, row}, favorites, follows} or :error. The
  # articles and the viewers' favorites go out together; the follows once the articles' authors are known (`users`:
  # the comment authors, known from phase A).
  # The arrays every viewer chunk shares (the plan's ids, its authors) are encoded once.
  defp phase_b(ids, users, viewers, chunk, io) do
    viewer_parts = if viewers == [], do: [], else: Enum.chunk_every(viewers, chunk)
    arts = send_all(for(part <- Enum.chunk_every(ids, chunk), do: {:plan_articles, [part]}), io)

    favs =
      if ids == [] or viewer_parts == [] do
        []
      else
        all_ids = Proto.encode_param(Proto.int8_array(), ids)
        send_all(for(part <- viewer_parts, do: {:plan_favs, [part, all_ids]}), io)
      end

    # :error unless every statement answered
    with {:ok, art_rows} <- await_all(arts, io) do
      # each article rendered (without body) as it arrives
      articles =
        Map.new(art_rows, fn row ->
          {id, author, pieces} = Render.plan_article(row, nil)
          {id, {author, pieces, row}}
        end)

      authors = Enum.uniq(for({_, {author, _, _}} <- articles, do: author) ++ users)

      follows =
        if authors == [] or viewer_parts == [] do
          []
        else
          all_authors = Proto.encode_param(Proto.int8_array(), authors)
          send_all(for(part <- viewer_parts, do: {:plan_follows, [part, all_authors]}), io)
        end

      with {:ok, fav_rows} <- await_all(favs, io),
           {:ok, follow_rows} <- await_all(follows, io) do
        {articles, pairs(fav_rows), pairs(follow_rows)}
      end
    end
    |> case do
      {_, _, _} = b -> b
      _ -> :error
    end
  end

  defp send_all(items, io), do: for(item <- items, do: io.async(:read, [item], :spread))

  # every handle's rows, concatenated, or :error (all are awaited either way)
  defp await_all(handles, io), do: await_all(handles, [], :ok, io)

  defp await_all([], got, :ok, _io), do: {:ok, Enum.concat(got)}
  defp await_all([], _got, :error, _io), do: :error

  defp await_all([handle | rest], got, status, io) do
    case io.await_raw(handle) do
      {:ok, [rows]} -> await_all(rest, [rows | got], status, io)
      _ -> await_all(rest, got, :error, io)
    end
  end

  defp pairs(rows),
    do: Map.new(rows, fn <<8::32, a::64-signed, 8::32, b::64-signed>> -> {{a, b}, true} end)

  # ------------------------------------------------------------------ responses

  # Every article and comment of the plan rendered once: {:list, id} / {:full, slug key} => {a, b, c, author id},
  # {:thread, slug key} => [{a, c, author id} | :none].
  defp pieces(ok, {arts, _, _}) do
    lists =
      for {id, {author, {a, b, c}, _row}} <- arts, into: %{}, do: {{:list, id}, {a, b, c, author}}

    full =
      for {:article_by_slug, got} <- ok,
          {key, {id, body}} <- got,
          %{^id => {_, _, row}} <- [arts],
          into: %{} do
        {_id, author, {a, b, c}} = Render.plan_article(row, body)
        {{:full, key}, {a, b, c, author}}
      end

    threads =
      for {:comments, got} <- ok, {key, thread} <- got, into: %{} do
        {{:thread, key},
         for c <- thread do
           case c do
             :none -> :none
             {author, {a, c}} -> {a, c, author}
           end
         end}
      end

    lists |> Map.merge(full) |> Map.merge(threads)
  end

  defp body(:article_by_slug, _params, nil, _pieces, _favs, _follows), do: nil
  defp body(:comments, _params, nil, _pieces, _favs, _follows), do: nil

  defp body(:article_by_slug, [v | _] = params, {id, _body}, pieces, favs, follows) do
    case Map.fetch(pieces, {:full, key(:article_by_slug, params)}) do
      {:ok, {a, b, c, author}} ->
        ["{\"article\":", a, flag(favs, v, id), b, flag(follows, v, author), c, "}"]

      :error ->
        :fallback
    end
  end

  defp body(:comments, [v | _] = params, _thread, pieces, _favs, follows) do
    items =
      for {a, c, author} <- Map.fetch!(pieces, {:thread, key(:comments, params)}),
          do: [a, flag(follows, v, author), c]

    ["{\"comments\":[", Enum.intersperse(items, ?,), "]}"]
  end

  defp body(kind, [v | _], {n, ids}, pieces, favs, follows) do
    feed? = kind == :feed

    items =
      for id <- ids do
        case pieces do
          # a feed's authors were reached through the viewer's follows (the single statement says true)
          %{{:list, ^id} => {a, b, c, author}} ->
            [a, flag(favs, v, id), b, if(feed?, do: "true", else: flag(follows, v, author)), c]

          _ ->
            throw(:fallback)
        end
      end

    [
      "{\"articles\":[",
      Enum.intersperse(items, ?,),
      "],\"articlesCount\":",
      Integer.to_string(n),
      "}"
    ]
  catch
    :fallback -> :fallback
  end

  defp flag(_set, 0, _x), do: "false"
  defp flag(set, v, x), do: if(is_map_key(set, {v, x}), do: "true", else: "false")
end
