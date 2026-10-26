defmodule Conduit.JSON do
  @moduledoc """
  JSON output, written as iodata straight from Postgres's binary column values (no maps, no encoder).
  Strings take a fast path when they contain nothing to escape (one Aho-Corasick scan in C).
  """

  import Bitwise, only: [>>>: 2, &&&: 2]

  @pattern_key {__MODULE__, :escape}

  def init do
    chars = ["\"", "\\" | for(c <- 0..31, do: <<c>>)]
    :persistent_term.put(@pattern_key, :binary.compile_pattern(chars))
  end

  @compile {:inline, str: 1, bool: 1}

  def str(nil), do: "null"

  def str(s) do
    case :binary.match(s, :persistent_term.get(@pattern_key)) do
      :nomatch -> [?", s, ?"]
      _ -> [?", escape(s), ?"]
    end
  end

  def bool(true), do: "true"
  def bool(_), do: "false"

  def escape(s), do: splice(s, :binary.matches(s, :persistent_term.get(@pattern_key)), 0)

  defp splice(s, [], last), do: [binary_part(s, last, byte_size(s) - last)]

  defp splice(s, [{pos, 1} | rest], last),
    do: [binary_part(s, last, pos - last), esc(:binary.at(s, pos)) | splice(s, rest, pos + 1)]

  defp esc(?"), do: "\\\""
  defp esc(?\\), do: "\\\\"
  defp esc(?\n), do: "\\n"
  defp esc(?\r), do: "\\r"
  defp esc(?\t), do: "\\t"
  defp esc(?\b), do: "\\b"
  defp esc(?\f), do: "\\f"
  defp esc(c), do: ["\\u00", hex(c >>> 4), hex(c &&& 15)]

  defp hex(n) when n < 10, do: ?0 + n
  defp hex(n), do: ?a + n - 10

  @doc "A list of strings as a JSON array."
  def str_list([]), do: "[]"
  def str_list([h | t]), do: [?[, str(h) | str_list_tail(t)]
  defp str_list_tail([]), do: [?]]
  defp str_list_tail([h | t]), do: [?,, str(h) | str_list_tail(t)]

  @doc """
  Postgres's text[] output literal -> a JSON array of strings. `{a,b,c}` has an element quoted (`"..."`, with `\\`
  escapes) only when it contains a delimiter, brace, quote, backslash or whitespace, or is empty or NULL-like; so a
  literal with no `"` and no control byte is plain names between commas, and the JSON is one C-level replace.
  """
  def pg_array_to_json("{}"), do: "[]"

  def pg_array_to_json(<<?{, rest::binary>>) do
    inner = binary_part(rest, 0, byte_size(rest) - 1)

    if :binary.match(inner, :persistent_term.get(@pattern_key)) == :nomatch do
      ["[\"", :binary.replace(inner, ",", "\",\"", [:global]), "\"]"]
    else
      str_list(pg_elems(inner, []))
    end
  end

  defp pg_elems(<<>>, acc), do: :lists.reverse(acc)
  defp pg_elems(<<?,, rest::binary>>, acc), do: pg_elems(rest, acc)
  defp pg_elems(<<?", rest::binary>>, acc), do: pg_quoted(rest, [], acc)

  defp pg_elems(bin, acc) do
    case :binary.match(bin, ",") do
      {pos, 1} -> pg_elems(binary_part(bin, pos + 1, byte_size(bin) - pos - 1), [binary_part(bin, 0, pos) | acc])
      :nomatch -> :lists.reverse([bin | acc])
    end
  end

  defp pg_quoted(<<?\\, c, rest::binary>>, cur, acc), do: pg_quoted(rest, [c | cur], acc)
  defp pg_quoted(<<?", rest::binary>>, cur, acc), do: pg_elems(rest, [IO.iodata_to_binary(:lists.reverse(cur)) | acc])
  defp pg_quoted(<<c, rest::binary>>, cur, acc), do: pg_quoted(rest, [c | cur], acc)

  @doc "iodata elements joined with commas inside []"
  def array([]), do: "[]"
  def array([h | t]), do: [?[, h | array_tail(t)]
  defp array_tail([]), do: [?]]
  defp array_tail([h | t]), do: [?,, h | array_tail(t)]

  # ---------- timestamps ----------
  # Postgres binary timestamptz: microseconds since 2000-01-01T00:00:00Z. Output: "YYYY-MM-DDTHH:MM:SS.mmmZ",
  # truncated (not rounded) to milliseconds.

  @d2 List.to_tuple(for n <- 0..99, do: String.pad_leading(Integer.to_string(n), 2, "0"))
  @d3 List.to_tuple(for n <- 0..999, do: String.pad_leading(Integer.to_string(n), 3, "0"))

  def ts(us) when us >= 0 do
    ms = div(us, 1000)
    secs = div(ms, 1000)
    days = div(secs, 86_400)
    format(days, secs - days * 86_400, ms - secs * 1000)
  end

  def ts(us) do
    ms = Integer.floor_div(us, 1000)
    secs = Integer.floor_div(ms, 1000)
    days = Integer.floor_div(secs, 86_400)
    format(days, secs - days * 86_400, ms - secs * 1000)
  end

  defp format(days, sod, msr) do
    {y, m, d} = civil(days + 10_957)
    h = div(sod, 3600)
    mi = div(rem(sod, 3600), 60)
    s = rem(sod, 60)

    <<?", year(y)::binary, ?-, elem(@d2, m)::binary, ?-, elem(@d2, d)::binary, ?T, elem(@d2, h)::binary, ?:,
      elem(@d2, mi)::binary, ?:, elem(@d2, s)::binary, ?., elem(@d3, msr)::binary, "Z\"">>
  end

  defp year(y) when y >= 1000 and y <= 9999, do: Integer.to_string(y)
  defp year(y) when y >= 0, do: String.pad_leading(Integer.to_string(y), 4, "0")
  defp year(y), do: Integer.to_string(y)

  # days since 1970-01-01 -> {y, m, d} (Howard Hinnant's civil_from_days)
  def civil(z0) do
    z = z0 + 719_468
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
