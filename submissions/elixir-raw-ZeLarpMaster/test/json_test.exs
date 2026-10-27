defmodule Conduit.JsonTest do
  use ExUnit.Case, async: true
  alias Conduit.Json

  @pg_epoch_micros 946_684_800_000_000

  defp s(v), do: v |> Json.str() |> IO.iodata_to_binary()

  test "string escaping" do
    assert s(~S(a "b" \c)) == ~S("a \"b\" \\c")
    assert s("x\ny\u0001") == ~S("x\ny\u0001")
    assert s("ünïcode <b>&</b>") == "\"ünïcode <b>&</b>\""
    assert :json.decode(s("\u0000\u001f\"\\\t\e")) == "\u0000\u001f\"\\\t\e"
    assert s("plain") == ~S("plain")
  end

  test "error body and nulls" do
    assert Json.error("no \"way\"") |> IO.iodata_to_binary() == ~S({"errors":{"body":["no \"way\""]}})
    assert Json.opt_str(nil) == "null"
  end

  test "timestamps are truncated to milliseconds" do
    unix = 1_743_508_800 * 1_000_000 + 123_999
    assert Json.ts(unix - @pg_epoch_micros) == ~S("2025-04-01T12:00:00.123Z")
    assert Json.ts(0) == ~S("2000-01-01T00:00:00.000Z")
    assert Json.ts(-1) == ~S("1999-12-31T23:59:59.999Z")
    assert Json.ts(1_709_208_000 * 1_000_000 - @pg_epoch_micros) == ~S("2024-02-29T12:00:00.000Z")
  end
end
