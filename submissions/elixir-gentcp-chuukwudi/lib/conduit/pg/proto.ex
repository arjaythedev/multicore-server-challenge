defmodule Conduit.PG.Proto do
  @moduledoc """
  PostgreSQL frontend/backend protocol 3.0: the messages this client sends, and decoders for the binary-format
  values it receives. Every statement is prepared once per connection; a query is Bind + Execute (+ Sync), with all
  parameters and all result columns in binary format.
  """
  @oid_int4 23
  @oid_int8 20
  @oid_text 25
  @oid_int4_array 1007
  @oid_int8_array 1016
  @oid_text_array 1009

  def oid(:int4), do: @oid_int4
  def oid(:int8), do: @oid_int8
  def oid(:text), do: @oid_text
  def oid(:int4_array), do: @oid_int4_array
  def oid(:int8_array), do: @oid_int8_array
  def oid(:text_array), do: @oid_text_array

  # ---------- raw socket writes ----------

  # What gen_tcp.send/2 does, minus the parts we don't need: the inet driver wants each write prefixed with a tagged
  # header (prim_inet uses a fresh monitor reference and then waits for `{inet_reply, port, status, tag}`). We use a
  # constant tag and don't wait: data is queued by the driver in order, a busy port still suspends the caller, and
  # a failed socket also shows up as tcp_closed. Long-lived callers drop the `{inet_reply, _, _, :w}` messages.
  @send_tag :w
  @send_hdr (fn ->
               b = :erlang.term_to_binary(:w)
               <<byte_size(b)::16, b::binary>>
             end).()

  def send_tag, do: @send_tag

  @doc "Write iodata to a gen_tcp socket without waiting. true, or raises ArgumentError for a closed port."
  def write(port, data), do: :erlang.port_command(port, [@send_hdr | data])

  # ---------- frontend messages ----------

  def startup(params) do
    body = [<<3::16, 0::16>>, Enum.map(params, fn {k, v} -> [k, 0, v, 0] end), 0]
    [<<IO.iodata_length(body) + 4::32>>, body]
  end

  def parse(name, sql, oids) do
    body = [name, 0, sql, 0, <<length(oids)::16>>, Enum.map(oids, &<<&1::32>>)]
    msg(?P, body)
  end

  def sync, do: <<?S, 4::32>>
  def terminate, do: <<?X, 4::32>>
  def password(pw), do: msg(?p, [pw, 0])

  # Bind (all parameters binary; results binary unless `formats` says otherwise) + Execute (no row limit).
  # Params are iodata values or nil (NULL). `formats` is the encoded result-format-code list.
  @all_binary <<1::16, 1::16>>
  def bind_execute(name, params, formats \\ @all_binary) do
    {vals, size} = encode_params(params, [], 0)
    n = length(params)
    len = 4 + byte_size(name) + 2 + 4 + 2 + size + byte_size(formats)
    [<<?B, len::32, 0>>, name, <<0, 1::16, 1::16, n::16>>, vals, formats, <<?E, 9::32, 0, 0::32>>]
  end

  @doc "Result format codes: one per column, 0 = text, 1 = binary."
  def formats(codes), do: IO.iodata_to_binary([<<length(codes)::16>> | Enum.map(codes, &<<&1::16>>)])

  defp encode_params([], acc, size), do: {Enum.reverse(acc), size}
  defp encode_params([nil | t], acc, size), do: encode_params(t, [<<-1::32-signed>> | acc], size + 4)

  defp encode_params([v | t], acc, size) do
    l = IO.iodata_length(v)
    encode_params(t, [v, <<l::32>> | acc], size + 4 + l)
  end

  defp msg(type, body), do: [type, <<IO.iodata_length(body) + 4::32>>, body]

  # ---------- binary parameter encoding ----------

  def enc_int8(v), do: <<v::64-signed>>
  def enc_int4(v), do: <<v::32-signed>>

  @doc "A one-dimensional array of non-null values, binary format."
  def array(type, values) do
    {body, n} = array_elems(type, values, [], 0)
    [<<1::32, 0::32, oid(type)::32, n::32, 1::32>> | body]
  end

  defp array_elems(_type, [], acc, n), do: {Enum.reverse(acc), n}
  defp array_elems(:int4, [v | t], acc, n), do: array_elems(:int4, t, [<<4::32, v::32-signed>> | acc], n + 1)
  defp array_elems(:int8, [v | t], acc, n), do: array_elems(:int8, t, [<<8::32, v::64-signed>> | acc], n + 1)

  defp array_elems(:text, [v | t], acc, n),
    do: array_elems(:text, t, [v, <<byte_size(v)::32>> | acc], n + 1)

  # ---------- binary result decoding (each returns {value, rest}) ----------

  @compile {:inline, text: 1, int8: 1, bool: 1, ts: 1, skip: 1}

  def text(<<-1::32-signed, rest::binary>>), do: {nil, rest}
  def text(<<len::32, v::binary-size(len), rest::binary>>), do: {v, rest}

  def int8(<<8::32, v::64-signed, rest::binary>>), do: {v, rest}
  def int8(<<-1::32-signed, rest::binary>>), do: {nil, rest}

  def bool(<<1::32, b, rest::binary>>), do: {b == 1, rest}
  def bool(<<-1::32-signed, rest::binary>>), do: {nil, rest}

  # timestamptz: microseconds since 2000-01-01 UTC
  def ts(<<8::32, v::64-signed, rest::binary>>), do: {v, rest}
  def ts(<<-1::32-signed, rest::binary>>), do: {nil, rest}

  def skip(<<-1::32-signed, rest::binary>>), do: rest
  def skip(<<len::32, _::binary-size(len), rest::binary>>), do: rest

  @doc "A text[] column: {[binary], rest}, or {nil, rest} for NULL."
  def text_array(<<-1::32-signed, rest::binary>>), do: {nil, rest}

  def text_array(<<len::32, arr::binary-size(len), rest::binary>>) do
    {decode_text_array(arr), rest}
  end

  defp decode_text_array(<<0::32, _::binary>>), do: []

  defp decode_text_array(<<1::32, _flags::32, _oid::32, _n::32, _lb::32, elems::binary>>),
    do: text_elems(elems)

  defp text_elems(<<>>), do: []
  defp text_elems(<<-1::32-signed, rest::binary>>), do: text_elems(rest)
  defp text_elems(<<len::32, v::binary-size(len), rest::binary>>), do: [v | text_elems(rest)]

  # ---------- backend messages ----------

  @doc "ErrorResponse fields -> %{code, message}"
  def error_fields(payload) do
    payload
    |> :binary.split(<<0>>, [:global])
    |> Enum.reduce(%{code: nil, message: nil}, fn
      <<?C, code::binary>>, acc -> %{acc | code: code}
      <<?M, m::binary>>, acc -> %{acc | message: m}
      _, acc -> acc
    end)
  end

  # ---------- authentication (SCRAM-SHA-256 and MD5) ----------

  def md5_password(user, pw, salt) do
    inner = Base.encode16(:crypto.hash(:md5, [pw, user]), case: :lower)
    "md5" <> Base.encode16(:crypto.hash(:md5, [inner, salt]), case: :lower)
  end

  def scram_client_first do
    nonce = Base.encode64(:crypto.strong_rand_bytes(18))
    bare = "n=,r=" <> nonce
    {nonce, bare, "n,," <> bare}
  end

  def sasl_initial(first), do: msg(?p, ["SCRAM-SHA-256", 0, <<byte_size(first)::32>>, first])

  def scram_client_final(pw, client_bare, server_first) do
    attrs = for kv <- String.split(server_first, ","), into: %{}, do: List.to_tuple(String.split(kv, "=", parts: 2))
    salt = Base.decode64!(attrs["s"])
    iters = String.to_integer(attrs["i"])
    salted = :crypto.pbkdf2_hmac(:sha256, pw, salt, iters, 32)
    client_key = :crypto.mac(:hmac, :sha256, salted, "Client Key")
    stored = :crypto.hash(:sha256, client_key)
    without_proof = "c=biws,r=" <> attrs["r"]
    auth_msg = Enum.join([client_bare, server_first, without_proof], ",")
    sig = :crypto.mac(:hmac, :sha256, stored, auth_msg)
    proof = :crypto.exor(client_key, sig)
    server_key = :crypto.mac(:hmac, :sha256, salted, "Server Key")
    server_sig = :crypto.mac(:hmac, :sha256, server_key, auth_msg)
    {msg(?p, [without_proof, ",p=", Base.encode64(proof)]), server_sig}
  end
end
