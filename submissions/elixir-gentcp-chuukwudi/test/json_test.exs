defmodule Conduit.JSONTest do
  use ExUnit.Case, async: true
  alias Conduit.JSON

  setup_all do
    JSON.init()
    :ok
  end

  defp out(io), do: IO.iodata_to_binary(io)

  test "strings round-trip through a JSON decoder" do
    for s <- ["plain", "", "quote \" and \\ backslash", "tab\tnl\ncr\r", <<1, 2, 31>>, "ünïcode ✓ 🙂", "</script>"] do
      assert :json.decode(out(JSON.str(s))) == s
    end

    assert out(JSON.str(nil)) == "null"
  end

  test "Postgres text[] literals become the same JSON array" do
    cases = [
      {"{}", []},
      {"{a,b,c}", ["a", "b", "c"]},
      {~S({"a b",c}), ["a b", "c"]},
      {~S({"with,comma","quo\"te","back\\slash",""}), ["with,comma", "quo\"te", "back\\slash", ""]},
      {<<"{x", 1, "y,z}">>, [<<"x", 1, "y">>, "z"]},
      {"{ünï,z}", ["ünï", "z"]}
    ]

    for {lit, want} <- cases, do: assert(:json.decode(out(JSON.pg_array_to_json(lit))) == want, lit)
  end

  test "timestamps: RFC 3339, UTC, 3 digits, truncated" do
    epoch = DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)

    for dt <- [
          ~U[2025-04-01 12:00:00.999999Z],
          ~U[2000-01-01 00:00:00Z],
          ~U[2024-02-29 23:59:59.000999Z],
          ~U[1999-12-31 23:59:59.123456Z],
          ~U[2026-10-23 08:09:10.5Z]
        ] do
      us = DateTime.to_unix(dt, :microsecond) - epoch
      {ms, _} = dt.microsecond

      want =
        "\"" <>
          Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S") <> "." <> String.pad_leading("#{div(ms, 1000)}", 3, "0") <> "Z\""

      assert JSON.ts(us) == want
    end
  end
end
