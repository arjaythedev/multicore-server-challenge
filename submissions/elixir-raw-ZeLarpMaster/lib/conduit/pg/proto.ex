defmodule Conduit.Pg.Proto do
  @moduledoc false
  # PostgreSQL wire protocol v3: the frontend messages we send and the decoding of the backend messages we read.
  # Parameters and results are always binary format, encoded and decoded by type oid.

  @int2 21
  @int4 23
  @int8 20
  @bool 16
  @text 25
  @timestamp 1114
  @timestamptz 1184
  @text_array 1009
  @varchar_array 1015
  @int4_array 1007
  @int8_array 1016

  # ------------------------------------------------------------------ frontend

  def startup(user, database, params) do
    kv = for {k, v} <- [{"user", user}, {"database", database} | params], do: [k, 0, v, 0]
    body = [<<196_608::32>>, kv, 0]
    [<<IO.iodata_length(body) + 4::32>>, body]
  end

  def password(data), do: msg(?p, data)
  def sasl_initial(mechanism, data), do: msg(?p, [mechanism, 0, <<byte_size(data)::32>>, data])

  def parse(name, sql), do: msg(?P, [name, 0, sql, 0, <<0::16>>])
  def describe_statement(name), do: msg(?D, [?S, name, 0])
  def sync, do: <<?S, 4::32>>

  @execute <<?E, 9::32, 0, 0::32>>

  @doc "Bind (unnamed portal, binary parameters and results) + Execute for statement `name_z` (name with its NUL)."
  def bind_execute(name_z, param_oids, params) do
    {vals, n} = params(param_oids, params, [], 0)
    body = [0, name_z, <<1::16, 1::16, n::16>>, vals, <<1::16, 1::16>>]
    [?B, <<IO.iodata_length(body) + 4::32>>, body, @execute]
  end

  defp msg(type, body), do: [type, <<IO.iodata_length(body) + 4::32>>, body]

  defp params([oid | oids], [v | vs], acc, n), do: params(oids, vs, [acc, param(oid, v)], n + 1)
  defp params([], [], acc, n), do: {acc, n}

  defp param(_, nil), do: <<-1::32-signed>>
  defp param(@int8, v) when is_integer(v), do: <<8::32, v::64-signed>>
  defp param(@int4, v) when is_integer(v), do: <<4::32, v::32-signed>>
  defp param(@int2, v) when is_integer(v), do: <<2::32, v::16-signed>>
  defp param(@bool, true), do: <<1::32, 1>>
  defp param(@bool, false), do: <<1::32, 0>>

  defp param(oid, v) when oid in [@timestamp, @timestamptz] and is_integer(v),
    do: <<8::32, v::64-signed>>

  defp param(oid, list) when oid in [@text_array, @varchar_array] and is_list(list),
    do: array(@text, list, &text_elem/1)

  defp param(@int8_array, list) when is_list(list), do: array(@int8, list, &int8_elem/1)
  defp param(@int4_array, list) when is_list(list), do: array(@int4, list, &int4_elem/1)
  # text, varchar, name, unknown: the bytes as they are
  defp param(_, v) when is_binary(v), do: [<<byte_size(v)::32>>, v]

  defp array(elem_oid, [], _enc), do: <<12::32, 0::32, 0::32, elem_oid::32>>

  defp array(elem_oid, list, enc) do
    body = [<<1::32, 0::32, elem_oid::32, length(list)::32, 1::32>> | Enum.map(list, enc)]
    [<<IO.iodata_length(body)::32>>, body]
  end

  defp text_elem(nil), do: <<-1::32-signed>>
  defp text_elem(s), do: [<<byte_size(s)::32>>, s]
  defp int8_elem(nil), do: <<-1::32-signed>>
  defp int8_elem(i), do: <<8::32, i::64-signed>>
  defp int4_elem(nil), do: <<-1::32-signed>>
  defp int4_elem(i), do: <<4::32, i::32-signed>>

  # ------------------------------------------------------------------ backend

  @doc "A DataRow's columns (after the column count), decoded by the statement's result column oids."
  def decode_row(cols, oids), do: cols(cols, oids, [])

  defp cols(<<-1::32-signed, rest::binary>>, [_ | oids], acc), do: cols(rest, oids, [nil | acc])

  defp cols(<<len::32, v::binary-size(len), rest::binary>>, [oid | oids], acc),
    do: cols(rest, oids, [value(oid, v) | acc])

  defp cols(<<>>, [], acc), do: :lists.reverse(acc)

  defp value(@int8, <<i::64-signed>>), do: i
  defp value(@int4, <<i::32-signed>>), do: i
  defp value(@int2, <<i::16-signed>>), do: i
  defp value(@bool, <<b>>), do: b == 1

  # timestamps stay raw microseconds since 2000-01-01: Conduit.Json.ts/1 formats them without DateTime structs
  defp value(@timestamptz, <<i::64-signed>>), do: i
  defp value(@timestamp, <<i::64-signed>>), do: i

  defp value(oid, v) when oid in [@text_array, @varchar_array, @int4_array, @int8_array],
    do: array_value(v)

  defp value(_, v), do: v

  defp array_value(<<0::32, _flags::32, _oid::32>>), do: []

  defp array_value(<<1::32, _flags::32, oid::32, _n::32, _lbound::32, elems::binary>>),
    do: elems(elems, oid, [])

  defp elems(<<-1::32-signed, rest::binary>>, oid, acc), do: elems(rest, oid, [nil | acc])

  defp elems(<<len::32, v::binary-size(len), rest::binary>>, oid, acc),
    do: elems(rest, oid, [value(oid, v) | acc])

  defp elems(<<>>, _oid, acc), do: :lists.reverse(acc)

  @doc "ParameterDescription body -> parameter type oids."
  def param_oids(<<_n::16, oids::binary>>), do: for(<<oid::32 <- oids>>, do: oid)

  @doc "RowDescription body -> result column type oids."
  def column_oids(<<_n::16, fields::binary>>), do: fields(fields, [])

  defp fields(<<>>, acc), do: :lists.reverse(acc)

  defp fields(bin, acc) do
    [_name, <<_table::32, _attnum::16, oid::32, _len::16, _mod::32, _format::16, rest::binary>>] =
      :binary.split(bin, <<0>>)

    fields(rest, [oid | acc])
  end

  @doc "ErrorResponse/NoticeResponse body -> %{code: SQLSTATE, message: text}."
  def error_fields(body) do
    for <<t, _::binary>> = f <- :binary.split(body, <<0>>, [:global]), t in [?C, ?M], into: %{} do
      <<_, v::binary>> = f
      {if(t == ?C, do: :code, else: :message), v}
    end
  end
end
