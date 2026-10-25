defmodule ConduitWeb.TimestampsTest do
  use ExUnit.Case, async: true

  alias ConduitWeb.Timestamps

  defp reference(datetime), do: datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  test "truncates to milliseconds, zero-padded, in UTC" do
    assert Timestamps.format(~U[2025-04-01 12:00:00.000000Z]) == "2025-04-01T12:00:00.000Z"
    assert Timestamps.format(~U[2025-04-01 09:05:07.999999Z]) == "2025-04-01T09:05:07.999Z"
    assert Timestamps.format(~U[2025-12-31 23:59:59Z]) == "2025-12-31T23:59:59.000Z"
    assert Timestamps.format(~U[0999-01-02 03:04:05.006Z]) == "0999-01-02T03:04:05.006Z"
  end

  test "matches DateTime.to_iso8601/1 on any time" do
    for _ <- 1..10_000 do
      us = Enum.random(-62_135_596_800_000_000..253_402_300_799_999_999)
      datetime = DateTime.from_unix!(us, :microsecond)
      assert Timestamps.format(datetime) == reference(datetime), inspect(datetime)
    end
  end

  test "takes the general path for other offsets" do
    datetime = %{~U[2025-04-01 12:00:00.123456Z] | utc_offset: 3600, time_zone: "Etc/GMT-1", zone_abbr: "+01"}
    assert Timestamps.format(datetime) == reference(datetime)
  end
end
