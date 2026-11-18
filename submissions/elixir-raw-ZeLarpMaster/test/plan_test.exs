defmodule Conduit.PlanTest do
  # Read plans rendered by the NIF's plan context (PLAN_NIF=1) against Conduit.Plan's Erlang path (PLAN_NIF=0), both
  # run end to end (Conduit.Plan.run/4) on a stand-in for Conduit.Pg that answers every plan statement from a random
  # model, as Postgres would in binary format: same answers for every request, fallbacks included. The end-to-end
  # check against the previous build is local/concurrency_check.py --reference.
  use ExUnit.Case, async: true

  alias Conduit.Plan
  alias Conduit.Render.Nif

  # ------------------------------------------------------------------ binary-format columns

  defp null, do: <<-1::32-signed>>
  defp text(s), do: <<byte_size(s)::32, s::binary>>
  defp opt(nil), do: null()
  defp opt(s), do: text(s)
  defp int8(i), do: <<8::32, i::64-signed>>

  defp array(elem_oid, elems, enc) do
    case elems do
      [] ->
        <<12::32, 0::32, 0::32, elem_oid::32>>

      _ ->
        body =
          IO.iodata_to_binary([
            <<1::32, 0::32, elem_oid::32, length(elems)::32, 1::32>> | Enum.map(elems, enc)
          ])

        <<byte_size(body)::32, body::binary>>
    end
  end

  defp int8_array(ids), do: array(20, ids, &int8/1)
  defp text_array(list), do: array(25, list, &text/1)

  # ------------------------------------------------------------------ the model

  @nasty [
    for(c <- 0..127, into: "", do: <<c>>),
    ~S(say "hi" \ bye),
    "ünïcode 🙂 " <> <<0xE2, 0x80, 0xA8>> <> " line",
    "",
    "plain words"
  ]

  @users 12
  # ids above @articles appear in pages but not in plan_articles (deleted between the phases): fallback
  @articles 60

  defp pick, do: Enum.random(@nasty)

  defp model(fail) do
    users =
      Map.new(1..@users, fn u ->
        {u,
         %{
           name: "user-#{u}-" <> pick(),
           bio: Enum.random([nil, pick()]),
           image: Enum.random([nil, "i.png"])
         }}
      end)

    articles =
      Map.new(1..@articles, fn i ->
        {i,
         %{
           slug: "slug-#{i}",
           title: pick(),
           desc: pick(),
           body: pick(),
           created: :rand.uniform(1_000_000_000_000_000) - 100_000_000,
           updated: :rand.uniform(1_000_000_000_000_000),
           tags: Enum.take(Enum.shuffle(@nasty), :rand.uniform(3) - 1),
           favc: :rand.uniform(3000) - 1,
           author: :rand.uniform(@users)
         }}
      end)

    comments =
      Map.new(1..@articles, fn i ->
        {i,
         for j <- 1..(:rand.uniform(4) - 1)//1 do
           %{
             id: i * 100 + j,
             body: pick(),
             created: j * 1000,
             updated: j * 2000,
             author: :rand.uniform(@users)
           }
         end}
      end)

    pairs = fn n, max ->
      MapSet.new(for _ <- 1..n, do: {:rand.uniform(@users), :rand.uniform(max)})
    end

    %{
      users: users,
      articles: articles,
      by_slug: Map.new(articles, fn {id, a} -> {a.slug, id} end),
      comments: comments,
      favs: pairs.(150, @articles + 2),
      follows: pairs.(50, @users),
      fail: fail
    }
  end

  # ------------------------------------------------------------------ the statements

  defmodule FakePg do
    @moduledoc false
    # Conduit.Pg's async/3 and await_raw/1 for Conduit.Plan.run/4, answering from the test's model.
    def async(:read, [{stmt, params}], :spread) do
      # the plan's small reads run in a process of their own
      m = Process.get(:plan_test_model) || :persistent_term.get(:plan_test_model)

      # the count lane's statements fail with the plan_articles they replace
      failing = if stmt in [:plan_articles_nc, :plan_counts], do: :plan_articles, else: stmt

      if failing in m.fail,
        do: {:error, :injected},
        else: {:rows, Conduit.PlanTest.answer(stmt, params, m)}
    end

    def await_raw({:rows, rows}), do: {:ok, [rows]}
    def await_raw(error), do: error
  end

  defp ints({:encoded, <<_::32, 0::32, _::binary>>}), do: []

  defp ints({:encoded, <<_::32, 1::32, _::32, 20::32, _n::32, 1::32, elems::binary>>}),
    do: for(<<8::32, i::64-signed <- elems>>, do: i)

  defp ints(list) when is_list(list), do: list

  # a page for a key: up to 6 ids, newest first; a capped count
  defp page(stmt, key) do
    h = :erlang.phash2({stmt, key})
    ids = for j <- 0..rem(h, 7)//1, do: rem(div(h, j + 1) * (j + 3), @articles + 2) + 1
    {rem(h, 1500), ids |> Enum.uniq() |> Enum.sort(:desc)}
  end

  @doc false
  def answer(:tags, [], m), do: [tags_row(m)]

  def answer(:plan_profile, [viewers, names], m) do
    for {{v, name}, i} <- Enum.with_index(Enum.zip(viewers, names), 1),
        row = profile_row(v, name, m),
        row != nil,
        do: int8(i) <> row
  end

  def answer(:plan_feed_heavy, [viewers], m) do
    for {f, u} <- m.follows, f in viewers, rem(u, 2) == 0, uniq: true, do: int8(u)
  end

  def answer(:plan_slug, [slugs], m) do
    for {slug, i} <- Enum.with_index(slugs, 1), id = m.by_slug[slug], id != nil do
      IO.iodata_to_binary([int8(i), int8(id), text(m.articles[id].body)])
    end
  end

  def answer(:plan_comments, [slugs], m) do
    for {slug, i} <- Enum.with_index(slugs, 1),
        id = m.by_slug[slug],
        id != nil,
        row <- comment_rows(i, id, m) do
      row
    end
  end

  def answer(:plan_counts, [ids], m) do
    for id <- Enum.uniq(ints(ids)) do
      count = if a = m.articles[id], do: a.favc, else: 0
      int8(id) <> int8(count)
    end
  end

  # a placeholder count, which the lane's replaces
  def answer(:plan_articles_nc, [ids], m), do: article_rows(ids, m, fn _ -> 0 end)
  def answer(:plan_articles, [ids], m), do: article_rows(ids, m, & &1.favc)

  def answer(stmt, [viewers, xs], m) when stmt in [:plan_favs, :plan_follows] do
    set = MapSet.new(ints(xs))
    pairs = if stmt == :plan_favs, do: m.favs, else: m.follows
    for {v, x} <- pairs, v in viewers, x in set, do: IO.iodata_to_binary([int8(v), int8(x)])
  end

  # the list kinds and the feed: one row per key
  def answer(stmt, columns, _m) do
    columns = if stmt == :plan_feed, do: Enum.drop(columns, -1), else: columns

    for {key, i} <- columns |> Enum.zip() |> Enum.with_index(1) do
      {n, ids} = page(stmt, key)
      IO.iodata_to_binary([int8(i), int8(n), int8_array(ids)])
    end
  end

  defp article_rows(ids, m, count) do
    for id <- ints(ids), a = m.articles[id], a != nil do
      u = m.users[a.author]

      IO.iodata_to_binary([
        int8(id),
        text(a.slug),
        text(a.title),
        text(a.desc),
        int8(a.created),
        int8(a.updated),
        text_array(a.tags),
        int8(count.(a)),
        int8(a.author),
        text(u.name),
        opt(u.bio),
        opt(u.image)
      ])
    end
  end

  @doc false
  def tags_row(m) do
    names = for({_, a} <- m.articles, t <- a.tags, uniq: true, do: t) |> Enum.sort()
    text_array(names)
  end

  # the single profile statement's row (id, username, bio, image, following), nil for an unknown name
  @doc false
  def profile_row(v, name, m) do
    case Enum.find(m.users, fn {_, u} -> u.name == name end) do
      {id, u} ->
        following = if {v, id} in m.follows, do: 1, else: 0

        IO.iodata_to_binary([
          int8(id),
          text(u.name),
          opt(u.bio),
          opt(u.image),
          <<1::32, following>>
        ])

      nil ->
        nil
    end
  end

  defp comment_rows(i, id, m) do
    case m.comments[id] do
      [] ->
        [IO.iodata_to_binary([int8(i), int8(id) | List.duplicate(null(), 8)])]

      cs ->
        for c <- cs do
          u = m.users[c.author]

          IO.iodata_to_binary([
            int8(i),
            int8(id),
            int8(c.id),
            text(c.body),
            int8(c.created),
            int8(c.updated),
            int8(c.author),
            text(u.name),
            opt(u.bio),
            opt(u.image)
          ])
        end
    end
  end

  # ------------------------------------------------------------------ requests

  defp request do
    v = :rand.uniform(@users + 1) - 1
    l = Enum.random([1, 3, 20])
    o = Enum.random([0, 1])
    k = Enum.random(["a", "b", "c"])
    slug = Enum.random(["slug-#{:rand.uniform(@articles)}", "nope"])

    case :rand.uniform(7) do
      1 -> {:list_all, [v, l, o]}
      2 -> {:list_tag, [v, l, o, k]}
      3 -> {:list_author, [v, l, o, k]}
      4 -> {:list_favorited, [v, l, o, k]}
      5 -> {:feed, [v, l, o, l + o]}
      6 -> {:article_by_slug, [v, slug]}
      7 -> {:comments, [v, slug]}
    end
  end

  # each request's answer through run/4
  defp answers(reqs, chunk, nif) do
    plan = for {kind, params} <- reqs, do: {:plan, :erlang.alias(), kind, params}
    :ok = Plan.run(plan, chunk, nif, FakePg)

    for {:plan, ref, _, _} <- plan do
      receive do
        {^ref, {:ok, body}} -> {:ok, body && IO.iodata_to_binary(body)}
        {^ref, :fallback} -> :fallback
      after
        # the small reads answer from a process of their own
        1000 -> flunk("no answer")
      end
      |> tap(fn _ -> :erlang.unalias(ref) end)
    end
  end

  test "the NIF's plans answer as the Erlang path, with or without the count lane" do
    start_supervised!({Conduit.PlanCounts, io: FakePg})

    counts =
      for _ <- 1..300, reduce: %{} do
        counts ->
          fail =
            Enum.random([
              [],
              [],
              [],
              [],
              [:plan_tag],
              [:plan_comments],
              [:plan_follows],
              [:plan_articles]
            ])

          m = model(fail)
          Process.put(:plan_test_model, m)
          # for the count lane's process
          :persistent_term.put(:plan_test_model, m)
          reqs = for _ <- 1..:rand.uniform(80), do: request()
          chunk = Enum.random([1, 2, 3, 128])
          erl = answers(reqs, chunk, false)
          nif = answers(reqs, chunk, true)
          assert nif == erl
          assert answers(reqs, chunk, :counts) == erl

          for {:ok, body} <- nif, body != nil, do: :json.decode(body)
          Enum.reduce(nif, counts, fn a, c -> Map.update(c, elem_or(a), 1, &(&1 + 1)) end)
      end

    # every outcome was exercised
    assert counts[:body] > 1000 and counts[nil] > 50 and counts[:fallback] > 50
  after
    :persistent_term.erase(:plan_test_model)
  end

  test "tags and profiles in plans answer as their single statements" do
    for _ <- 1..200 do
      fail = Enum.random([[], [], [:tags], [:plan_profile], [:plan_articles]])
      m = model(fail)
      Process.put(:plan_test_model, m)
      :persistent_term.put(:plan_test_model, m)
      names = for({_, u} <- m.users, do: u.name) ++ ["nobody"]

      small =
        for _ <- 1..:rand.uniform(40) do
          if :rand.uniform(2) == 1,
            do: {:tags, []},
            else: {:profile, [:rand.uniform(@users + 1) - 1, Enum.random(names)]}
        end

      # with or without article reads in the same plan
      reqs = Enum.shuffle(small ++ for(_ <- 1..Enum.random([0, 5])//1, do: request()))

      for {{kind, params}, answer} <-
            Enum.zip(reqs, answers(reqs, Enum.random([1, 2, 128]), true)),
          kind in [:tags, :profile] do
        expected =
          cond do
            kind == :tags and :tags in fail -> :fallback
            kind == :profile and :plan_profile in fail -> :fallback
            kind == :tags -> {:ok, Nif.tags(tags_row(m))}
            row = profile_row(hd(params), List.last(params), m) -> {:ok, Nif.profile(row)}
            true -> {:ok, nil}
          end

        assert answer == expected
      end
    end
  after
    :persistent_term.erase(:plan_test_model)
  end

  # a plan_articles row's columns after its id
  defp answer_tail do
    [text("s"), text("t"), text("d"), int8(0), int8(0), text_array([]), int8(0), int8(1), text("u"), null(), null()]
  end

  defp elem_or({:ok, nil}), do: nil
  defp elem_or({:ok, _}), do: :body
  defp elem_or(:fallback), do: :fallback

  test "plan contexts: parameters, owner, malformed rows" do
    plan = Nif.plan_new()
    row = IO.iodata_to_binary([int8(1), int8(5), int8_array([30, 10, 20])])
    :ok = Nif.plan_add(plan, 0, 0, [row])
    :ok = Nif.plan_add(plan, 1, 3, [row])
    {all, parts} = Nif.plan_ids(plan, 2)
    encode = &Conduit.Pg.Proto.encode_param(Conduit.Pg.Proto.int8_array(), &1)
    assert all == encode.([30, 10, 20])
    assert parts == [encode.([30, 10]), encode.([20])]
    assert Nif.plan_authors(plan) == {0, encode.([])}
    assert Nif.plan_ids(Nif.plan_new(), 128) == {encode.([]), []}

    # pages need their articles; missing slugs and threads are nil
    ref = make_ref()

    assert Nif.plan_bodies(plan, [{ref, 0, 0, 1}, {ref, 0, 1, 1}, {ref, 5, 0, 1}, {ref, 6, 9, 0}]) ==
             [{ref, :fallback}, {ref, :fallback}, {ref, {:ok, nil}}, {ref, {:ok, nil}}]

    # the same slot twice, short and long rows, rows that aren't binaries, another process
    assert_raise ArgumentError, fn -> Nif.plan_add(plan, 0, 0, [row]) end
    assert_raise ArgumentError, fn -> Nif.plan_add(plan, 2, 0, [binary_part(row, 0, 30)]) end
    assert_raise ArgumentError, fn -> Nif.plan_add(plan, 2, 0, [row <> <<0>>]) end
    assert_raise ArgumentError, fn -> Nif.plan_add(plan, 8, 0, [row]) end
    assert_raise ArgumentError, fn -> Nif.plan_add(plan, 7, 0, [:row]) end
    assert_raise ArgumentError, fn -> Nif.plan_add(plan, 11, 0, []) end
    assert_raise ArgumentError, fn -> Nif.plan_bodies(plan, [{ref, 7, 0, 0}]) end

    # counts: before any article, and every article then needs one
    counted = Nif.plan_new()
    :ok = Nif.plan_add(counted, 10, 0, [int8(30) <> int8(4)])
    assert_raise ArgumentError, fn -> Nif.plan_add(counted, 10, 0, [int8(30) <> int8(-1)]) end

    assert_raise ArgumentError, fn ->
      Nif.plan_add(counted, 10, 0, [int8(30) <> int8(2_147_483_648)])
    end

    article = fn id -> IO.iodata_to_binary([int8(id), answer_tail()]) end
    :ok = Nif.plan_add(counted, 7, 0, [article.(30)])
    assert_raise ArgumentError, fn -> Nif.plan_add(counted, 7, 0, [article.(31)]) end
    assert_raise ArgumentError, fn -> Nif.plan_add(counted, 10, 0, []) end

    task = Task.async(fn -> catch_error(Nif.plan_ids(plan, 1)) end)
    assert Task.await(task) == :badarg
  end
end
