defmodule Conduit.UtilTest do
  use ExUnit.Case, async: true
  alias Conduit.Util

  defp page(q), do: q |> Util.parse_query() |> Util.page()

  test "limit and offset" do
    assert page("") == {:ok, 20, 0}
    assert page("limit=05&offset=005") == {:ok, 5, 5}
    assert page("limit=3&limit=500") == {:ok, 3, 0}

    for bad <- ["limit=0", "limit=101", "limit=-1", "limit=abc", "limit=", "limit=1.5", "limit=%2B5", "limit=%205",
                "offset=-1", "offset=abc", "offset=", "offset=99999999999999999999"] do
      assert page(bad) == :error, bad
    end
  end

  test "filters" do
    q = Util.parse_query("tag=&author=bob&favorited=al")
    assert q["tag"] == nil and q["author"] == "bob" and q["favorited"] == "al"
    assert Util.parse_query("tag=a+b%20c")["tag"] == "a b c"
    assert Util.parse_query("tag=a&tag=b")["tag"] == "a"
    assert Util.parse_query("li%6Dit=7") == %{"limit" => "7"}
  end

  test "digits" do
    assert Util.parse_digits("005") == 5
    assert Util.parse_digits("") == nil
    assert Util.parse_digits("+5") == nil
    assert Util.parse_digits(" 5") == nil
    assert Util.parse_digits("9223372036854775807") == 9_223_372_036_854_775_807
    assert Util.parse_digits("9223372036854775808") == nil
  end

  test "path segments" do
    assert Util.decode_segment("abc-1") == "abc-1"
    assert Util.decode_segment("a%20b") == "a b"
    assert Util.decode_segment("a%2") == "a%2"
    assert Util.decode_segment("a+b") == "a+b"
    assert Util.decode_segment("a%00b") == nil
    assert Util.decode_segment("%ff") == nil
  end

  # init/0 swaps the raw patterns for compiled ones (persistent_term, global to the test VM): same answers.
  test "compiled patterns match as the raw ones" do
    inputs = ["", "abc", "a%20b", "a+b", "a+b%2", "%", "+", "a\0b", "%00", "x%2By+z", "%e2%82%ac+%"]
    queries = ["tag=a+b%20c", "author=%00", "li%6Dit=7&offset=+1", "favorited=a%2Bb"]

    run = fn ->
      {for(s <- inputs, plus? <- [true, false], do: Util.pct_decode(s, plus?)),
       Enum.map(inputs, &Util.decode_segment/1), Enum.map(inputs, &Util.nul?/1),
       Enum.map(queries, &Util.parse_query/1)}
    end

    raw = run.()
    Util.init()
    assert run.() == raw
    assert Util.nul?("a\0b") and not Util.nul?("ab")
  end
end
