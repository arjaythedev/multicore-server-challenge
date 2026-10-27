defmodule Conduit.Types.PlainIntegerTest do
  use ExUnit.Case, async: true

  alias Conduit.Types.PlainInteger

  test "casts plain digits" do
    assert {:ok, 0} = PlainInteger.cast("0")
    assert {:ok, 25} = PlainInteger.cast("25")
    assert {:ok, 9_223_372_036_854_775_807} = PlainInteger.cast("9223372036854775807")
    assert {:ok, 5} = PlainInteger.cast("00000000000000000005")
  end

  test "rejects signs, spaces, decimals and anything too big for a bigint" do
    for value <- [
          "+5",
          "-5",
          " 5",
          "5 ",
          "5\n",
          "5a",
          "1_000",
          "٥",
          "5.0",
          "",
          "abc",
          "9223372036854775808",
          -1,
          1.5,
          nil
        ] do
      assert :error = PlainInteger.cast(value), "expected #{inspect(value)} to be rejected"
    end
  end
end
