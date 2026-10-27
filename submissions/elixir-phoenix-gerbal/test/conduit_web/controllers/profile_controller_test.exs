defmodule ConduitWeb.ProfileControllerTest do
  use ConduitWeb.ConnCase, async: true

  test "shows, follows and unfollows", %{conn: conn} do
    celeb = user_fixture()
    fan = authenticate(conn, user_fixture())

    assert %{"profile" => %{"username" => username, "following" => false, "bio" => nil}} =
             conn |> get(~p"/api/profiles/#{celeb.username}") |> json_response(200)

    assert username == celeb.username

    assert %{"profile" => %{"following" => true}} =
             fan |> post(~p"/api/profiles/#{celeb.username}/follow") |> json_response(200)

    assert %{"profile" => %{"following" => true}} =
             fan |> get(~p"/api/profiles/#{celeb.username}") |> json_response(200)

    assert %{"profile" => %{"following" => false}} =
             fan |> delete(~p"/api/profiles/#{celeb.username}/follow") |> json_response(200)
  end

  test "unknown users are a 404", %{conn: conn} do
    assert conn |> get(~p"/api/profiles/nobody-here") |> json_response(404)
  end

  # Postgres rejects text that isn't UTF-8, and phoenix_ecto makes that error a 400, as Plug does for a query string.
  test "a username that isn't UTF-8 is a 400", %{conn: conn} do
    assert {400, _headers, body} = assert_error_sent(400, fn -> get(conn, "/api/profiles/%FF") end)
    assert %{"errors" => %{"body" => ["Bad Request"]}} = JSON.decode!(body)
  end

  test "an invalid token is a 401 even where auth is optional", %{conn: conn} do
    celeb = user_fixture()
    conn = conn |> put_req_header("authorization", "Token not-a-jwt") |> get(~p"/api/profiles/#{celeb.username}")
    assert json_response(conn, 401)
  end
end
