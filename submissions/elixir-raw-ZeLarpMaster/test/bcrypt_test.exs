defmodule Conduit.BcryptTest do
  # Our bcrypt NIF checked against bcrypt_elixir (an independent implementation, test-only dependency), the seed's
  # real hashes, and itself across batch sizes.
  use ExUnit.Case, async: false

  alias Conduit.Bcrypt.Nif

  # a user from the seed, password "password123"
  @seeded "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"

  setup_all do
    {:ok, _} = Conduit.Bcrypt.start_link(workers: 1, window_ms: 20)
    :ok
  end

  defp random_password do
    case :rand.uniform(4) do
      1 -> ""
      2 -> String.duplicate("é", :rand.uniform(36))
      _ -> for _ <- 1..:rand.uniform(72), into: <<>>, do: <<:rand.uniform(255)>>
    end
  end

  test "verifies the seed's hashes" do
    assert Conduit.Bcrypt.verify("password123", @seeded)
    refute Conduit.Bcrypt.verify("password124", @seeded)
    refute Conduit.Bcrypt.verify("password123", "not a hash")
  end

  test "agrees with bcrypt_elixir both ways, at cost 4" do
    for _ <- 1..40 do
      pw = random_password()
      # theirs, checked by ours
      theirs = Bcrypt.hash_pwd_salt(pw, log_rounds: 4)
      assert Nif.hash([pw], [theirs]) == [theirs]
      # ours, checked by theirs
      [ours] =
        Nif.hash([pw], [String.replace(Nif.salt(:crypto.strong_rand_bytes(16)), "$10$", "$04$")])

      assert Bcrypt.verify_pass(pw, ours)
    end
  end

  test "hash/1 and verify/2 at cost 10, also checked by bcrypt_elixir" do
    {:ok, hash} = Conduit.Bcrypt.hash("correct horse")
    assert String.starts_with?(hash, "$2b$10$") and byte_size(hash) == 60
    assert Bcrypt.verify_pass("correct horse", hash)
    assert Conduit.Bcrypt.verify("correct horse", hash)
    refute Conduit.Bcrypt.verify("correct horsf", hash)
  end

  test "every batch size gives the single-hash results" do
    for _ <- 1..10 do
      inputs =
        for _ <- 1..4 do
          {random_password(),
           String.replace(Nif.salt(:crypto.strong_rand_bytes(16)), "$10$", "$04$")}
        end

      singles = for {k, s} <- inputs, do: hd(Nif.hash([k], [s]))

      for n <- 2..4 do
        {keys, settings} = inputs |> Enum.take(n) |> Enum.unzip()
        assert Nif.hash(keys, settings) == Enum.take(singles, n)
      end
    end
  end

  test "concurrent verifications through the collector all come out right" do
    good = Bcrypt.hash_pwd_salt("secret", log_rounds: 10)

    results =
      1..12
      |> Enum.map(fn i ->
        Task.async(fn ->
          Conduit.Bcrypt.verify(if(rem(i, 3) == 0, do: "wrong", else: "secret"), good)
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert results == for(i <- 1..12, do: rem(i, 3) != 0)
  end

  test "rejects what bcrypt can't take" do
    setting = Nif.salt(:crypto.strong_rand_bytes(16))
    assert Nif.hash([String.duplicate("a", 73)], [setting]) == :error
    assert Nif.hash(["a\0b"], [setting]) == :error
    assert Nif.hash(["a"], ["$2b$10$short"]) == :error
    assert Nif.hash(["a", "b"], [setting]) == :error
    # lanes of different costs can't be interleaved; the collector then computes each alone
    assert Nif.hash(["a", "b"], [setting, String.replace(setting, "$10$", "$04$")]) == :error
  end
end
