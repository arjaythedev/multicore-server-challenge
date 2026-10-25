defmodule Conduit.Accounts.TokenTest do
  use ExUnit.Case, async: true

  alias Conduit.Accounts.Token

  @secret Application.compile_env!(:joken, :default_signer)

  defp sign(claims, alg \\ "HS256", secret \\ @secret) do
    {:ok, token, _claims} = Joken.encode_and_sign(claims, Joken.Signer.create(alg, secret))
    token
  end

  defp now, do: System.system_time(:second)

  test "issues exactly sub, iat and exp, 30 days apart" do
    {:ok, claims} = 42 |> Token.sign() |> Token.verify_and_validate()

    assert %{"sub" => "42", "iat" => iat, "exp" => exp} = claims
    assert map_size(claims) == 3
    assert exp - iat == 30 * 24 * 60 * 60
  end

  test "accepts a valid token" do
    assert {:ok, 7} = Token.fetch_user_id(sign(%{"sub" => "7", "iat" => now(), "exp" => now() + 60}))
  end

  test "rejects a wrong signature, another algorithm, or alg none" do
    claims = %{"sub" => "7", "iat" => now(), "exp" => now() + 60}

    assert :error = Token.fetch_user_id(sign(claims, "HS256", "wrong secret"))
    assert :error = Token.fetch_user_id(sign(claims, "HS512"))

    [header, payload, _signature] = String.split(sign(claims), ".")
    none = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    assert :error = Token.fetch_user_id("#{none}.#{payload}.")
    assert :error = Token.fetch_user_id("#{header}.#{payload}.")
  end

  test "rejects an expired token or one without exp" do
    assert :error = Token.fetch_user_id(sign(%{"sub" => "7", "iat" => now() - 100, "exp" => now() - 10}))
    assert :error = Token.fetch_user_id(sign(%{"sub" => "7", "iat" => now()}))
  end

  test "rejects a sub that is missing or isn't a positive decimal string" do
    for sub <- [7, "abc", "+7", "7\n", "0", "", "99999999999999999999", nil] do
      assert :error = Token.fetch_user_id(sign(%{"sub" => sub, "iat" => now(), "exp" => now() + 60})), inspect(sub)
    end

    assert :error = Token.fetch_user_id(sign(%{"iat" => now(), "exp" => now() + 60}))
  end

  test "rejects garbage" do
    assert :error = Token.fetch_user_id("not a token")
  end
end
