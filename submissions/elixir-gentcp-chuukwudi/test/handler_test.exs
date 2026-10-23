defmodule Conduit.HandlerTest do
  use ExUnit.Case, async: true

  # SLUGIFY(x) = trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))
  defp reference(x) do
    x |> String.replace(~r/[^A-Za-z0-9]+/u, "-") |> String.downcase(:ascii) |> String.trim("-")
  end

  test "slugify matches the SQL definition" do
    for t <- [
          "Conformance: Hello, World! 2026",
          "  Conformance -- Renamed Title!  ",
          "",
          "---",
          "ÄÖÜ äöü",
          "a",
          "Zz9",
          "Ünïcode in the Middle of Words",
          "x-y_z",
          "🙂 emoji 🙂",
          "MiXeD CaSe"
        ] do
      assert Conduit.Handler.slugify(t) == reference(t), t
    end
  end
end
