defmodule Conduit.Pg.Scram do
  @moduledoc false
  # SCRAM-SHA-256 (RFC 5802/7677) as Postgres uses it: no channel binding, the user name comes from the startup
  # message, so the client-first message carries an empty one.

  @gs2 "n,,"

  def client_first do
    nonce = Base.encode64(:crypto.strong_rand_bytes(18))
    bare = "n=,r=" <> nonce
    {@gs2 <> bare, %{bare: bare, nonce: nonce}}
  end

  @doc "server-first -> {client-final, expected server signature}."
  def client_final(server_first, password, %{bare: bare, nonce: nonce}) do
    %{"r" => r, "s" => s, "i" => i} = attrs(server_first)
    true = String.starts_with?(r, nonce)
    salted = :crypto.pbkdf2_hmac(:sha256, password, Base.decode64!(s), String.to_integer(i), 32)
    client_key = hmac(salted, "Client Key")
    without_proof = "c=" <> Base.encode64(@gs2) <> ",r=" <> r
    auth = bare <> "," <> server_first <> "," <> without_proof
    proof = :crypto.exor(client_key, hmac(:crypto.hash(:sha256, client_key), auth))
    server_sig = hmac(hmac(salted, "Server Key"), auth)
    {without_proof <> ",p=" <> Base.encode64(proof), server_sig}
  end

  def verify_final(server_final, server_sig) do
    case attrs(server_final) do
      %{"v" => v} -> :crypto.hash_equals(Base.decode64!(v), server_sig)
      _ -> false
    end
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp attrs(msg) do
    for <<k, ?=, v::binary>> <- String.split(msg, ","), into: %{}, do: {<<k>>, v}
  end
end
