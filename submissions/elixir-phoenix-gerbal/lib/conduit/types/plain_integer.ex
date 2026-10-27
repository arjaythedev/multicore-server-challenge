defmodule Conduit.Types.PlainInteger do
  @moduledoc """
  A non-negative integer that casts only from plain decimal digits (leading zeros allowed) that fit in a bigint.

  Ecto's `:integer` also accepts strings like `"+5"`; query parameters and ids here must be digits and nothing else.
  """
  use Ecto.Type

  @max 9_223_372_036_854_775_807

  @impl Ecto.Type
  def type, do: :integer

  @impl Ecto.Type
  def cast(value) when is_integer(value) and value in 0..@max, do: {:ok, value}

  def cast(value) when is_binary(value) and value != "" do
    if digits?(value) do
      value |> String.to_integer() |> in_range()
    else
      :error
    end
  end

  def cast(_value), do: :error

  # Matched byte by byte: a regex literal is recompiled on every call on OTP 28 and later, which made casting a page's
  # `limit` about ten times slower.
  defp digits?(<<digit, rest::binary>>) when digit in ?0..?9, do: digits?(rest)
  defp digits?(<<>>), do: true
  defp digits?(_value), do: false

  defp in_range(n) when n <= @max, do: {:ok, n}
  defp in_range(_n), do: :error

  @impl Ecto.Type
  def load(value), do: {:ok, value}

  @impl Ecto.Type
  def dump(value) when is_integer(value), do: {:ok, value}
  def dump(_value), do: :error
end
