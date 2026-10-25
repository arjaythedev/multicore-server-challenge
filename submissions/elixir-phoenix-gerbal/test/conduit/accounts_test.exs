defmodule Conduit.AccountsTest do
  use Conduit.DataCase, async: true

  alias Conduit.Accounts
  alias Conduit.Accounts.User

  describe "register_user/1" do
    test "hashes the password" do
      user = user_fixture(%{"password" => "secret"})

      assert user.password == nil
      assert Bcrypt.verify_pass("secret", user.password_hash)
    end

    test "requires a username, email and password" do
      assert {:error, changeset} = Accounts.register_user(%{"username" => "", "email" => nil})

      assert %{username: ["can't be blank"], email: ["can't be blank"], password: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "takes a value of only whitespace, which is not empty" do
      assert {:ok, %User{username: " "}} =
               Accounts.register_user(%{
                 "username" => " ",
                 "email" => "#{unique_username()}@example.com",
                 "password" => " "
               })
    end

    test "rejects non-string fields" do
      assert {:error, changeset} =
               Accounts.register_user(%{"username" => 123, "email" => "a@example.com", "password" => "pw"})

      assert %{username: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects passwords bcrypt would truncate" do
      attrs = %{"username" => unique_username(), "email" => "x@example.com", "password" => String.duplicate("p", 73)}

      assert {:error, changeset} = Accounts.register_user(attrs)
      assert %{password: ["should be at most 72 byte(s)"]} = errors_on(changeset)
    end

    test "rejects a taken username or email" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.register_user(%{"username" => user.username, "email" => "new@example.com", "password" => "pw"})

      assert %{username: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               Accounts.register_user(%{"username" => unique_username(), "email" => user.email, "password" => "pw"})

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "authenticate/1" do
    setup do
      %{user: user_fixture(%{"password" => "secret"})}
    end

    test "accepts the right password", %{user: user} do
      assert {:ok, %User{id: id}} = Accounts.authenticate(%{"email" => user.email, "password" => "secret"})
      assert id == user.id
    end

    test "rejects a wrong password or an unknown email", %{user: user} do
      assert {:error, :unauthorized} = Accounts.authenticate(%{"email" => user.email, "password" => "wrong"})
      assert {:error, :unauthorized} = Accounts.authenticate(%{"email" => "nobody@example.com", "password" => "x"})
    end

    test "looks up an email of only whitespace like any other" do
      assert {:error, :unauthorized} = Accounts.authenticate(%{"email" => " ", "password" => " "})
    end

    test "requires both fields" do
      assert {:error, %Ecto.Changeset{} = changeset} = Accounts.authenticate(%{"email" => ""})
      assert %{email: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "update_user/2" do
    setup do
      %{user: user_fixture(%{"password" => "secret"})}
    end

    test "leaves absent and null fields unchanged", %{user: user} do
      assert {:ok, updated} = Accounts.update_user(user, %{"bio" => "Hello", "email" => nil})

      assert updated.bio == "Hello"
      assert updated.email == user.email
      assert updated.password_hash == user.password_hash
    end

    test "can set bio to the empty string", %{user: user} do
      {:ok, user} = Accounts.update_user(user, %{"bio" => "Hello"})
      assert {:ok, %User{bio: ""}} = Accounts.update_user(user, %{"bio" => ""})
    end

    test "rehashes a new password", %{user: user} do
      assert {:ok, updated} = Accounts.update_user(user, %{"password" => "new secret"})
      assert Bcrypt.verify_pass("new secret", updated.password_hash)
    end

    test "rejects a blank email, a non-string bio and a taken username", %{user: user} do
      other = user_fixture()

      assert {:error, changeset} = Accounts.update_user(user, %{"email" => ""})
      assert %{email: ["should be at least 1 character(s)"]} = errors_on(changeset)

      assert {:error, changeset} = Accounts.update_user(user, %{"bio" => 5})
      assert %{bio: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} = Accounts.update_user(user, %{"username" => other.username})
      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "tokens" do
    test "round-trip the user id" do
      user = user_fixture()
      assert {:ok, user.id} == user |> Accounts.sign_token() |> Accounts.verify_token()
    end
  end
end
