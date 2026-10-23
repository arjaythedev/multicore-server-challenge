defmodule Conduit.JWTTest do
  use ExUnit.Case, async: false
  alias Conduit.JWT

  @secret "test-secret"
  setup_all do
    JWT.init(@secret)
    :ok
  end

  defp b64(x), do: Base.url_encode64(x, padding: false)

  defp mint(payload, secret \\ @secret, header \\ ~s({"alg":"HS256","typ":"JWT"})) do
    data = b64(header) <> "." <> b64(payload)
    data <> "." <> b64(:crypto.mac(:hmac, :sha256, secret, data))
  end

  defp now, do: System.os_time(:second)

  test "issued tokens verify and carry exactly sub, iat, exp = iat + 30 days" do
    t = JWT.sign(42)
    assert {:ok, 42} = JWT.verify(t)
    [_, p, _] = String.split(t, ".")
    claims = :json.decode(Base.url_decode64!(p, padding: false))
    assert Map.keys(claims) |> Enum.sort() == ["exp", "iat", "sub"]
    assert claims["sub"] == "42"
    assert claims["exp"] - claims["iat"] == 30 * 24 * 3600
  end

  test "both fast-path claim orders verify; the slow path agrees" do
    n = now()
    assert {:ok, 7} = JWT.verify(mint(~s({"exp":#{n + 60},"iat":#{n},"sub":"7"})))
    assert {:ok, 7} = JWT.verify(mint(~s({"sub":"7","iat":#{n},"exp":#{n + 60}})))
    # other shapes take the JSON decoder
    assert {:ok, 7} = JWT.verify(mint(~s({ "sub": "7", "exp": #{n + 60} })))
    assert {:ok, 7} = JWT.verify(mint(~s({"sub":"7","exp":#{n + 60}.0,"iat":#{n}})))
    assert {:ok, 7} = JWT.verify(mint(~s({"sub":"7","exp":#{n + 60},"iat":#{n},"nbf":#{n - 1}})))
  end

  test "rejections" do
    n = now()
    assert :error = JWT.verify(mint(~s({"sub":"7","iat":#{n},"exp":#{n - 10}})))
    assert :error = JWT.verify(mint(~s({"exp":#{n - 10},"iat":#{n},"sub":"7"})))
    assert :error = JWT.verify(mint(~s({"sub":"7","iat":#{n}})))
    assert :error = JWT.verify(mint(~s({"sub":7,"iat":#{n},"exp":#{n + 60}})))
    assert :error = JWT.verify(mint(~s({"sub":"abc","iat":#{n},"exp":#{n + 60}})))
    assert :error = JWT.verify(mint(~s({"sub":"","iat":#{n},"exp":#{n + 60}})))
    assert :error = JWT.verify(mint(~s({"sub":"7","iat":,"exp":#{n + 60}})))
    assert :error = JWT.verify(mint(~s({"exp":,"iat":#{n},"sub":"7"})))
    assert :error = JWT.verify(mint(~s({"sub":"7","exp":#{n + 60},"nbf":#{n + 100}})))
    assert :error = JWT.verify(mint(~s({"sub":"7","iat":#{n},"exp":#{n + 60}}), "wrong"))

    assert :error =
             JWT.verify(mint(~s({"sub":"7","iat":#{n},"exp":#{n + 60}}), @secret, ~s({"alg":"HS384","typ":"JWT"})))

    none = b64(~s({"alg":"none"})) <> "." <> b64(~s({"sub":"7","exp":#{n + 60}})) <> "."
    assert :error = JWT.verify(none)
    assert :error = JWT.verify("not.a.jwt")
    assert :error = JWT.verify("garbage")
    # a tampered payload with the original signature
    [h, _p, s] = String.split(mint(~s({"sub":"7","iat":#{n},"exp":#{n + 60}})), ".")
    assert :error = JWT.verify(h <> "." <> b64(~s({"sub":"8","iat":#{n},"exp":#{n + 60}})) <> "." <> s)
  end

  test "a non-standard header saying HS256 is accepted" do
    n = now()
    assert {:ok, 9} = JWT.verify(mint(~s({"sub":"9","exp":#{n + 60}}), @secret, ~s({"typ":"JWT","alg":"HS256"})))
  end
end
