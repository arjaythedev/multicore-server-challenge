defmodule Conduit.PgTs do
  @moduledoc false
  # timestamptz as raw microseconds since 2000-01-01 UTC: formatting by hand skips building DateTime structs.
  import Postgrex.BinaryUtils, warn: false
  use Postgrex.BinaryExtension, send: "timestamptz_send"

  def init(_opts), do: nil

  def encode(_) do
    quote location: :keep do
      micros when is_integer(micros) -> <<8::int32(), micros::int64()>>
    end
  end

  def decode(_) do
    quote location: :keep do
      <<8::int32(), micros::int64()>> -> micros
    end
  end
end

Postgrex.Types.define(Conduit.PgTypes, [Conduit.PgTs], [])
