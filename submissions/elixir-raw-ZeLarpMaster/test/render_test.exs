defmodule Conduit.RenderTest do
  # The render NIF against JSON assembled with Conduit.Json (what the Erlang renderer uses), on rows encoded as
  # Postgres sends them (binary format). The end-to-end check against the Erlang renderer is
  # local/concurrency_check.py --reference with RENDER_NIF=0 on the reference side.
  use ExUnit.Case, async: true

  alias Conduit.Json
  alias Conduit.Render.Nif

  @pg_epoch_micros 946_684_800_000_000

  # ------------------------------------------------------------------ binary-format column encoders

  defp null, do: <<-1::32-signed>>
  defp text(s), do: <<byte_size(s)::32, s::binary>>
  defp opt(nil), do: null()
  defp opt(s), do: text(s)
  defp int8(i), do: <<8::32, i::64-signed>>
  defp bool(b), do: <<1::32, if(b, do: 1, else: 0)>>
  defp ts(micros), do: int8(micros)

  defp text_array([]), do: <<12::32, 0::32, 0::32, 25::32>>

  defp text_array(list) do
    body =
      IO.iodata_to_binary([
        <<1::32, 0::32, 25::32, length(list)::32, 1::32>> | Enum.map(list, &text/1)
      ])

    <<byte_size(body)::32, body::binary>>
  end

  # ------------------------------------------------------------------ expected JSON, built as the handler does

  defp profile_json(u, bio, image, following),
    do: [
      "{\"username\":",
      Json.str(u),
      ",\"bio\":",
      Json.opt_str(bio),
      ",\"image\":",
      Json.opt_str(image),
      ",\"following\":",
      Json.bool(following),
      "}"
    ]

  defp article_json(a, body?) do
    [
      "{\"slug\":",
      Json.str(a.slug),
      ",\"title\":",
      Json.str(a.title),
      ",\"description\":",
      Json.str(a.desc),
      if(body?, do: [",\"body\":", Json.str(a.body)], else: []),
      ",\"tagList\":[",
      a.tags |> Enum.map(&Json.str/1) |> Enum.intersperse(?,),
      "],\"createdAt\":",
      Json.ts(a.created),
      ",\"updatedAt\":",
      Json.ts(a.updated),
      ",\"favorited\":",
      Json.bool(a.favd),
      ",\"favoritesCount\":",
      Json.int(a.favc),
      ",\"author\":",
      profile_json(a.user, a.bio, a.image, a.following),
      "}"
    ]
  end

  defp article_cols(a, body?) do
    [
      int8(a.id),
      text(a.slug),
      text(a.title),
      text(a.desc),
      if(body?, do: text(a.body), else: ""),
      ts(a.created),
      ts(a.updated),
      text_array(a.tags),
      int8(a.favc),
      bool(a.favd),
      text(a.user),
      opt(a.bio),
      opt(a.image),
      bool(a.following)
    ]
  end

  # every ASCII byte (all the control characters), quotes, backslashes, multi-byte UTF-8
  @nasty [
    for(c <- 0..127, into: "", do: <<c>>),
    ~S(say "hi" \ bye),
    "ünïcode 🙂 " <> <<0xE2, 0x80, 0xA8>> <> " line",
    "",
    "\b\f\n\r\t\e"
  ]

  defp random_article(i) do
    pick = fn -> Enum.random(@nasty ++ ["plain words", "mair-rior-troma-#{i}"]) end

    %{
      id: i,
      slug: "slug-#{i}",
      title: pick.(),
      desc: pick.(),
      body: pick.(),
      created:
        Enum.random([
          -@pg_epoch_micros - 123_456_789,
          0,
          780_000_000_123_456,
          4_000_000_000_000_000
        ]),
      updated: :rand.uniform(1_000_000_000_000_000),
      tags: Enum.take(Enum.shuffle(@nasty ++ ["stun", "nain"]), :rand.uniform(4) - 1),
      favc: :rand.uniform(3000) - 1,
      favd: :rand.uniform(2) == 1,
      user: pick.(),
      bio: Enum.random([nil, pick.()]),
      image: Enum.random([nil, "https://example.com/x.png"]),
      following: :rand.uniform(2) == 1
    }
  end

  defp bin(iodata), do: IO.iodata_to_binary(iodata)

  test "lists, with articles and empty" do
    for _ <- 1..200 do
      articles = for i <- 1..:rand.uniform(10), do: random_article(i)
      n = :rand.uniform(1000)
      rows = for a <- articles, do: bin([int8(n) | article_cols(a, false)])

      expected = [
        "{\"articles\":[",
        Enum.intersperse(Enum.map(articles, &article_json(&1, false)), ?,),
        "],\"articlesCount\":",
        Json.int(n),
        "}"
      ]

      assert Nif.list(rows) == bin(expected)
    end

    empty = bin([int8(7) | List.duplicate(null(), 13)])
    assert Nif.list([empty]) == ~S({"articles":[],"articlesCount":7})
    assert Nif.list([]) == ~S({"articles":[],"articlesCount":0})
  end

  test "article with body" do
    for i <- 1..200 do
      a = random_article(i)

      assert Nif.article(bin(article_cols(a, true))) ==
               bin(["{\"article\":", article_json(a, true), "}"])
    end
  end

  test "comments, with and without" do
    for _ <- 1..200 do
      cs = for i <- 1..:rand.uniform(6), do: random_article(i)

      rows =
        for c <- cs do
          bin([
            int8(42),
            int8(c.id),
            text(c.body),
            ts(c.created),
            ts(c.updated),
            text(c.user),
            opt(c.bio),
            opt(c.image),
            bool(c.following)
          ])
        end

      expected =
        for c <- cs do
          [
            "{\"id\":",
            Json.int(c.id),
            ",\"createdAt\":",
            Json.ts(c.created),
            ",\"updatedAt\":",
            Json.ts(c.updated),
            ",\"body\":",
            Json.str(c.body),
            ",\"author\":",
            profile_json(c.user, c.bio, c.image, c.following),
            "}"
          ]
        end

      assert Nif.comments(rows) == bin(["{\"comments\":[", Enum.intersperse(expected, ?,), "]}"])
    end

    assert Nif.comments([bin([int8(42) | List.duplicate(null(), 8)])]) == ~S({"comments":[]})
  end

  test "profile and tags" do
    for u <- @nasty, bio <- [nil, "a \"bio\""] do
      assert Nif.profile(bin([int8(1), text(u), opt(bio), null(), bool(true)])) ==
               bin(["{\"profile\":", profile_json(u, bio, nil, true), "}"])
    end

    assert Nif.tags(text_array(["a", "b\"c"])) == ~S({"tags":["a","b\"c"]})
    assert Nif.tags(text_array([])) == ~S({"tags":[]})
  end

  test "malformed rows raise instead of reading past them" do
    good = bin([int8(1), text("u"), null(), null(), bool(false)])
    assert_raise ArgumentError, fn -> Nif.profile(binary_part(good, 0, byte_size(good) - 1)) end
    assert_raise ArgumentError, fn -> Nif.profile(good <> <<0>>) end
    assert_raise ArgumentError, fn -> Nif.profile(<<1_000_000::32, "x">>) end

    assert_raise ArgumentError, fn ->
      Nif.profile(bin([int8(1), null(), null(), null(), bool(false)]))
    end

    assert_raise ArgumentError, fn -> Nif.list([:not_a_binary]) end
    assert_raise ArgumentError, fn -> Nif.list([good]) end
    assert_raise ArgumentError, fn -> Nif.tags(<<20::32, 1::32, 0::32, 25::32, 5::32, 1::32>>) end
  end
end
