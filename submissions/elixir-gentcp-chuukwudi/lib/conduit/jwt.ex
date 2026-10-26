defmodule Conduit.JWT do
  @moduledoc """
  HS256 JWTs. Every request's token has its signature (constant-time compare), `alg` and `exp` checked; nothing is
  remembered between requests. The secret's HMAC key schedule is OTP's business; we only pass the raw secret.
  """

  # base64url of {"alg":"HS256","typ":"JWT"}: the header we issue (and what most libraries issue). Any other header
  # is decoded and must say HS256.
  @std_header "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
  @ttl 30 * 24 * 3600

  def init(secret), do: :persistent_term.put(__MODULE__, secret)
  defp secret, do: :persistent_term.get(__MODULE__)

  def sign(id) do
    now = System.os_time(:second)
    payload = b64(~s({"sub":"#{id}","iat":#{now},"exp":#{now + @ttl}}))
    data = @std_header <> "." <> payload
    data <> "." <> b64(:crypto.mac(:hmac, :sha256, secret(), data))
  end

  @doc "{:ok, user_id} or :error"
  def verify(token) do
    with [h, p, s] <- :binary.split(token, ".", [:global]),
         43 <- byte_size(s),
         mac = b64(:crypto.mac(:hmac, :sha256, secret(), [h, ?., p])),
         true <- :crypto.hash_equals(mac, s),
         true <- header_ok?(h),
         {:ok, json} <- unb64(p) do
      now = System.os_time(:second)

      case fast_claims(json) do
        {sub, exp} when exp >= now ->
          {:ok, sub}

        {_, _} ->
          :error

        :slow ->
          case decode(json) do
            {:ok, %{} = claims} -> claims(claims, now)
            _ -> :error
          end
      end
    else
      _ -> :error
    end
  end

  # The two exact payload shapes in practice, already authenticated by the signature check above: ours
  # {"sub":"<id>","iat":<n>,"exp":<n>} and Go's sorted-key {"exp":<n>,"iat":<n>,"sub":"<id>"}. Anything else
  # (other claims, spacing, floats, nbf, ...) goes through the full JSON decoder.
  defp fast_claims(<<"{\"sub\":\"", r::binary>>) do
    with {sub, <<"\",\"iat\":", r::binary>>} when sub != nil <- num(r, 0, 0),
         {iat, <<",\"exp\":", r::binary>>} when iat != nil <- num(r, 0, 0),
         {exp, "}"} when exp != nil <- num(r, 0, 0) do
      {sub, exp}
    else
      _ -> :slow
    end
  end

  defp fast_claims(<<"{\"exp\":", r::binary>>) do
    with {exp, <<",\"iat\":", r::binary>>} when exp != nil <- num(r, 0, 0),
         {iat, <<",\"sub\":\"", r::binary>>} when iat != nil <- num(r, 0, 0),
         {sub, "\"}"} when sub != nil <- num(r, 0, 0) do
      {sub, exp}
    else
      _ -> :slow
    end
  end

  defp fast_claims(_), do: :slow

  # an unsigned decimal of 1-18 digits; {nil, rest} otherwise
  defp num(<<c, r::binary>>, acc, n) when c in ?0..?9 and n < 18, do: num(r, acc * 10 + c - ?0, n + 1)
  defp num(r, acc, n) when n > 0, do: {acc, r}
  defp num(r, _, _), do: {nil, r}

  defp header_ok?(@std_header), do: true

  defp header_ok?(h) do
    with {:ok, json} <- unb64(h),
         {:ok, %{"alg" => "HS256"}} <- decode(json) do
      true
    else
      _ -> false
    end
  end

  @b64 %{mode: :urlsafe, padding: false}
  defp b64(bin), do: :base64.encode(bin, @b64)

  defp unb64(text) do
    {:ok, :base64.decode(text, @b64)}
  rescue
    _ -> :error
  end

  defp decode(json) do
    {:ok, :json.decode(json)}
  rescue
    _ -> :error
  end

  defp claims(%{"sub" => sub, "exp" => exp} = c, now) when is_binary(sub) and is_number(exp) do
    with true <- exp >= now,
         true <- nbf_ok?(c, now),
         {:ok, id} <- id(sub) do
      {:ok, id}
    else
      _ -> :error
    end
  end

  defp claims(_, _), do: :error

  defp nbf_ok?(%{"nbf" => nbf}, now) when is_number(nbf), do: nbf <= now
  defp nbf_ok?(%{"nbf" => _}, _), do: false
  defp nbf_ok?(_, _), do: true

  defp id(sub) when byte_size(sub) in 1..18 do
    if digits?(sub), do: {:ok, String.to_integer(sub)}, else: :error
  end

  defp id(_), do: :error

  def digits?(<<>>), do: true
  def digits?(<<c, rest::binary>>) when c in ?0..?9, do: digits?(rest)
  def digits?(_), do: false
end
