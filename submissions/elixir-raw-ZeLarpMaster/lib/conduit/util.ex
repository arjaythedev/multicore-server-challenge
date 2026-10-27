defmodule Conduit.Util do
  @moduledoc false

  @max_i64 9_223_372_036_854_775_807

  @doc "Non-empty ASCII digits that fit in an i64 (no sign, no whitespace); nil otherwise."
  def parse_digits(""), do: nil

  def parse_digits(s) when is_binary(s) do
    if byte_size(s) <= 19 and all_digits?(s) do
      n = String.to_integer(s)
      if n <= @max_i64, do: n
    end
  end

  defp all_digits?(<<c, rest::binary>>) when c in ?0..?9, do: all_digits?(rest)
  defp all_digits?(<<>>), do: true
  defp all_digits?(_), do: false

  @doc "Percent-decodes one path segment. nil for invalid UTF-8 or an embedded NUL, which Postgres can't store in text."
  def decode_segment(s) do
    decoded = pct_decode(s, false)
    if String.valid?(decoded) and :binary.match(decoded, <<0>>) == :nomatch, do: decoded
  end

  @doc "Percent-decoding that keeps malformed escapes literally; `plus?` turns `+` into a space (query strings)."
  def pct_decode(s, plus?) do
    if :binary.match(s, if(plus?, do: ["%", "+"], else: ["%"])) == :nomatch do
      s
    else
      s |> do_decode(plus?, []) |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp do_decode(<<>>, _plus?, acc), do: acc

  defp do_decode(<<?%, h, l, rest::binary>>, plus?, acc) do
    case {hex(h), hex(l)} do
      {a, b} when a != nil and b != nil -> do_decode(rest, plus?, [<<a * 16 + b>> | acc])
      _ -> do_decode(<<h, l, rest::binary>>, plus?, ["%" | acc])
    end
  end

  defp do_decode(<<?+, rest::binary>>, true, acc), do: do_decode(rest, true, [" " | acc])
  defp do_decode(<<c, rest::binary>>, plus?, acc), do: do_decode(rest, plus?, [<<c>> | acc])

  defp hex(c) when c in ?0..?9, do: c - ?0
  defp hex(c) when c in ?a..?f, do: c - ?a + 10
  defp hex(c) when c in ?A..?F, do: c - ?A + 10
  defp hex(_), do: nil

  @doc """
  Query parameters we care about. The first occurrence of each wins; empty filters count as absent. Values with
  invalid UTF-8 are repaired the way a lossy decoder would, so they simply match nothing.
  """
  def parse_query(""), do: %{}

  def parse_query(query),
    do: query |> :binary.split("&", [:global]) |> Enum.reduce(%{}, &query_pair/2)

  defp query_pair(pair, acc) do
    {k, v} =
      case :binary.split(pair, "=") do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end

    case pct_decode(k, true) do
      key when key in ["limit", "offset"] ->
        put_new(acc, key, value(v))

      key when key in ["tag", "author", "favorited"] ->
        if v == "", do: acc, else: put_new(acc, key, value(v))

      _ ->
        acc
    end
  end

  defp value(v), do: v |> pct_decode(true) |> String.replace_invalid()

  defp put_new(acc, key, v), do: Map.put_new(acc, key, v)

  @doc "{:ok, limit, offset} from the `limit`/`offset` parameters (defaults 20 and 0), or :error for a 422."
  def page(q) do
    with {:ok, limit} <- bounded(Map.get(q, "limit"), 20, 1, 100),
         {:ok, offset} <- bounded(Map.get(q, "offset"), 0, 0, @max_i64) do
      {:ok, limit, offset}
    end
  end

  defp bounded(nil, default, _min, _max), do: {:ok, default}

  defp bounded(v, _default, min, max) do
    case parse_digits(v) do
      n when is_integer(n) and n >= min and n <= max -> {:ok, n}
      _ -> :error
    end
  end
end
