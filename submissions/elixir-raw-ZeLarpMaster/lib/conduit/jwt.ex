defmodule Conduit.Jwt do
  @moduledoc false
  # `Authorization: Token <jwt>`: HS256 tokens, verified on every request (signature, alg, exp, nbf). Nothing about a
  # verified token is remembered.

  # base64url of {"alg":"HS256","typ":"JWT"}: the header issued here and minted by the load generator.
  @std_header "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
  @ttl 30 * 24 * 60 * 60
  @max_id 9_223_372_036_854_775_807

  def init(secret) when is_binary(secret) and secret != "",
    do: :persistent_term.put({__MODULE__, :secret}, secret)

  def issue(user_id, now) do
    claims = [
      "{\"sub\":\"",
      Integer.to_string(user_id),
      "\",\"iat\":",
      Integer.to_string(now),
      ",\"exp\":",
      Integer.to_string(now + @ttl),
      "}"
    ]

    signing =
      [@std_header, ?., Base.url_encode64(IO.iodata_to_binary(claims), padding: false)]
      |> IO.iodata_to_binary()

    signing <> "." <> Base.url_encode64(sign(signing), padding: false)
  end

  @doc "A missing or empty header is anonymous; anything else must be a valid `Token <jwt>`."
  def check(nil, _now), do: :anonymous
  def check("", _now), do: :anonymous

  def check("Token " <> token, now) do
    case verify(token, now) do
      {:ok, id} -> {:user, id}
      :error -> :invalid
    end
  end

  def check(_other, _now), do: :invalid

  def verify(token, now) do
    with [header, payload, sig] <- :binary.split(token, ".", [:global]),
         true <- header_ok?(header),
         {:ok, sig_bytes} when byte_size(sig_bytes) == 32 <- b64url(sig),
         signed = binary_part(token, 0, byte_size(header) + 1 + byte_size(payload)),
         true <- :crypto.hash_equals(sign(signed), sig_bytes),
         {:ok, claims} <- b64url(payload),
         {:ok, sub, exp, nbf} <- claims(claims),
         true <- exp > now and (nbf == nil or nbf <= now) do
      {:ok, sub}
    else
      _ -> :error
    end
  end

  defp sign(data),
    do: :crypto.mac(:hmac, :sha256, :persistent_term.get({__MODULE__, :secret}), data)

  # OTP's :base64 decodes in chunks; Elixir's Base goes character by character (measured 1.7 us less per token).
  defp b64url(s) do
    {:ok, :base64.decode(s, %{mode: :urlsafe, padding: false})}
  rescue
    _ -> :error
  end

  defp header_ok?(@std_header), do: true

  defp header_ok?(header) do
    with {:ok, bytes} <- b64url(header),
         %{"alg" => "HS256"} <- decode_json(bytes) do
      true
    else
      _ -> false
    end
  end

  # Fast path for the flat shape every issuer here produces; anything else goes to the general parser, so both agree.
  defp claims(<<"{\"sub\":\"", rest::binary>> = all) do
    with {sub, <<"\",\"iat\":", rest::binary>>} <- digits(rest, 0, 0),
         {_iat, <<",\"exp\":", rest::binary>>} <- digits(rest, 0, 0),
         {exp, "}"} <- digits(rest, 0, 0),
         true <- sub > 0 and sub <= @max_id do
      {:ok, sub, exp, nil}
    else
      _ -> general_claims(all)
    end
  end

  defp claims(other), do: general_claims(other)

  defp digits(<<c, rest::binary>>, acc, n) when c in ?0..?9 and n < 18,
    do: digits(rest, acc * 10 + c - ?0, n + 1)

  defp digits(rest, acc, n) when n > 0, do: {acc, rest}
  defp digits(_rest, _acc, _n), do: :error

  defp general_claims(bytes) do
    with %{} = obj <- decode_json(bytes),
         {:ok, sub} <- sub(Map.get(obj, "sub")),
         {:ok, exp} <- int_claim(obj, "exp", false),
         {:ok, nbf} <- int_claim(obj, "nbf", true) do
      {:ok, sub, exp, nbf}
    else
      _ -> :error
    end
  end

  defp sub(s) when is_binary(s) do
    case Conduit.Util.parse_digits(s) do
      id when is_integer(id) and id > 0 and id <= @max_id -> {:ok, id}
      _ -> :error
    end
  end

  defp sub(_), do: :error

  defp int_claim(obj, key, optional?) do
    case Map.fetch(obj, key) do
      {:ok, v} when is_integer(v) -> {:ok, v}
      :error when optional? -> {:ok, nil}
      _ -> :error
    end
  end

  defp decode_json(bytes) do
    :json.decode(bytes)
  rescue
    _ -> nil
  end
end
