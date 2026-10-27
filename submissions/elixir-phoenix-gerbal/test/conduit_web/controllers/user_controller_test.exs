defmodule ConduitWeb.UserControllerTest do
  use ConduitWeb.ConnCase, async: true

  describe "POST /api/users" do
    test "registers and returns a token", %{conn: conn} do
      body = %{user: %{username: "jake", email: "jake@example.com", password: "jakejake"}}
      conn = post(conn, ~p"/api/users", JSON.encode!(body))

      assert %{"user" => %{"username" => "jake", "email" => "jake@example.com", "bio" => nil, "image" => nil} = user} =
               json_response(conn, 201)

      assert {:ok, _id} = Conduit.Accounts.verify_token(user["token"])
    end

    test "is 422 for missing fields, a missing wrapper, or a duplicate", %{conn: conn} do
      taken = user_fixture()

      for body <- [
            %{user: %{username: "x", email: "x@example.com"}},
            %{username: "x", email: "x@example.com", password: "pw"},
            %{user: "x"},
            %{user: %{username: taken.username, email: "x@example.com", password: "pw"}}
          ] do
        assert %{"errors" => %{"body" => [_ | _]}} = conn |> post(~p"/api/users", body) |> json_response(422)
      end
    end

    test "is 422 for a body that isn't JSON", %{conn: conn} do
      assert %{"errors" => %{"body" => [_]}} =
               conn |> post(~p"/api/users", ~s({"user": {"username": )) |> json_response(422)

      assert conn |> post(~p"/api/users", "") |> json_response(422)
    end
  end

  describe "POST /api/users/login" do
    test "logs in with the right password only", %{conn: conn} do
      user = user_fixture(%{"password" => "secret"})

      assert %{"user" => %{"username" => username}} =
               conn
               |> post(~p"/api/users/login", %{user: %{email: user.email, password: "secret"}})
               |> json_response(200)

      assert username == user.username

      assert conn
             |> post(~p"/api/users/login", %{user: %{email: user.email, password: "wrong"}})
             |> json_response(401)

      assert conn |> post(~p"/api/users/login", %{user: %{email: user.email}}) |> json_response(422)
    end
  end

  describe "GET and PUT /api/user" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: authenticate(conn, user)}
    end

    test "returns the current user with the presented token", %{conn: conn, user: user} do
      [token] = conn |> get_req_header("authorization") |> Enum.map(&String.replace_prefix(&1, "Token ", ""))

      assert %{"user" => %{"username" => username, "token" => ^token}} =
               conn |> get(~p"/api/user") |> json_response(200)

      assert username == user.username
    end

    test "updates", %{conn: conn} do
      assert %{"user" => %{"bio" => "Hi"}} =
               conn |> put(~p"/api/user", %{user: %{bio: "Hi"}}) |> json_response(200)

      assert conn |> put(~p"/api/user", %{user: %{email: ""}}) |> json_response(422)
    end

    test "a valid token for a user who no longer exists is a 401", %{conn: conn, user: user} do
      Conduit.Repo.delete!(user)

      assert conn |> get(~p"/api/user") |> json_response(401)
      assert conn |> put(~p"/api/user", %{user: %{bio: "Hi"}}) |> json_response(401)
    end

    test "requires a valid token", %{conn: conn} do
      conn = conn |> delete_req_header("authorization") |> get(~p"/api/user")
      assert json_response(conn, 401)

      for header <- ["Bearer x", "Token x", "Token"] do
        assert build_conn() |> put_req_header("authorization", header) |> get(~p"/api/user") |> json_response(401)
      end
    end
  end
end
