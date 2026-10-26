defmodule Conduit.Json do
  @moduledoc false
  # Hand-built iodata: responses are never assembled as maps and encoded.

  # Seconds between 1970-01-01 and 2000-01-01, the Postgres timestamp epoch.
  @pg_epoch_micros 946_684_800_000_000

  # OTP's string encoder: measured 2.5x faster than a compiled-pattern scan for the short strings responses are
  # mostly made of (33 vs 81 ns), 2.2x over a typical response's mix of strings.
  def str(s) when is_binary(s), do: :json.encode_binary(s)

  def opt_str(nil), do: "null"
  def opt_str(s), do: str(s)

  def bool(true), do: "true"
  def bool(false), do: "false"

  def int(i), do: Integer.to_string(i)

  def error(msg), do: ["{\"errors\":{\"body\":[", str(msg), "]}}"]

  @doc "A Postgres timestamptz (microseconds since 2000-01-01 UTC) as a quoted `YYYY-MM-DDTHH:MM:SS.mmmZ`, truncated to ms."
  def ts(pg_micros) do
    unix_micros = pg_micros + @pg_epoch_micros
    secs = Integer.floor_div(unix_micros, 1_000_000)
    ms = div(Integer.mod(unix_micros, 1_000_000), 1000)
    {y, m, d} = civil_from_days(Integer.floor_div(secs, 86_400))
    sod = Integer.mod(secs, 86_400)

    <<?", p2(div(y, 100))::binary, p2(rem(y, 100))::binary, ?-, p2(m)::binary, ?-, p2(d)::binary,
      ?T, p2(div(sod, 3600))::binary, ?:, p2(rem(div(sod, 60), 60))::binary, ?:,
      p2(rem(sod, 60))::binary, ?., div(ms, 100) + ?0, p2(rem(ms, 100))::binary, ?Z, ?">>
  end

  defp p2(v), do: <<div(v, 10) + ?0, rem(v, 10) + ?0>>

  # Howard Hinnant's civil_from_days: days since 1970-01-01 to {year, month, day}, proleptic Gregorian.
  def civil_from_days(z) do
    z = z + 719_468
    era = Integer.floor_div(z, 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365)
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = if mp < 10, do: mp + 3, else: mp - 9
    y = yoe + era * 400
    {if(m <= 2, do: y + 1, else: y), m, d}
  end
end
