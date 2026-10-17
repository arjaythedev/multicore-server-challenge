defmodule Conduit.JwtTest do
  use ExUnit.Case, async: true
  alias Conduit.Jwt

  @secret "s3cret"
  @now 1_800_000_000
  @hs ~s({"alg":"HS256"})

  setup_all do
    Jwt.init(@secret)
    :ok
  end

  defp mint(header, claims, secret \\ @secret) do
    msg = Base.url_encode64(header, padding: false) <> "." <> Base.url_encode64(claims, padding: false)
    sig = :crypto.mac(:hmac, :sha256, secret, msg)
    msg <> "." <> Base.url_encode64(sig, padding: false)
  end

  test "issue/verify roundtrip with the standard header and exp = iat + 30 days" do
    t = Jwt.issue(42, @now)
    assert String.starts_with?(t, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.")
    assert Jwt.verify(t, @now) == {:ok, 42}
    assert Jwt.verify(t, @now + 2_592_000) == :error
    [_, p, _] = String.split(t, ".")
    assert :json.decode(Base.url_decode64!(p, padding: false)) == %{"sub" => "42", "iat" => @now, "exp" => @now + 2_592_000}
  end

  test "accepts other HS256 headers and claim shapes" do
    assert Jwt.verify(mint(@hs, ~s({"sub":"7","exp":1900000000})), @now) == {:ok, 7}
    assert Jwt.verify(mint(@hs, ~s( { "exp" : 1900000000 , "x":[1], "sub":"9" } )), @now) == {:ok, 9}
  end

  test "rejections" do
    ok = ~s({"sub":"7","exp":1900000000})
    assert Jwt.verify(mint(@hs, ok, "other"), @now) == :error
    assert Jwt.verify(mint(~s({"alg":"none"}), ok), @now) == :error
    assert Jwt.verify(mint(~s({"alg":"HS512"}), ok), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":"7"})), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":7,"exp":1900000000})), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":"abc","exp":1900000000})), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":"0","exp":1900000000})), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":"7","exp":1})), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":"7","exp":1900000000,"nbf":1900000000})), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":"7","exp":1.9e9})), @now) == :error
    assert Jwt.verify(mint(@hs, ~s({"sub":"7","exp":"1900000000"})), @now) == :error
    assert Jwt.verify("not.a.jwt", @now) == :error
    assert Jwt.verify("a.b.c.d", @now) == :error
  end

  test "Authorization header forms" do
    t = Jwt.issue(42, @now)
    assert Jwt.check(nil, @now) == :anonymous
    assert Jwt.check("", @now) == :anonymous
    assert Jwt.check("Bearer " <> t, @now) == :invalid
    assert Jwt.check(t, @now) == :invalid
    assert Jwt.check("Token " <> t, @now) == {:user, 42}
    assert Jwt.check("Token garbage", @now) == :invalid
  end
end
