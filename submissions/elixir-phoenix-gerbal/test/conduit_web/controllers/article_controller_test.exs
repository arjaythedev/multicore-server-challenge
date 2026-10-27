defmodule ConduitWeb.ArticleControllerTest do
  use ConduitWeb.ConnCase, async: true

  @timestamp ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/

  setup %{conn: conn} do
    author = user_fixture()
    %{author: author, author_conn: authenticate(conn, author)}
  end

  test "publishes, shows, lists, edits and deletes an article", %{conn: conn, author_conn: author_conn} do
    [a, b] = [unique_tag("a"), unique_tag("b")]
    body = %{article: %{title: "How to train", description: "Ever wonder?", body: "Carefully.", tagList: [b, a]}}

    # Encoded, so the body goes through the endpoint's JSON parser as a client's would.
    assert %{"article" => %{"slug" => slug} = created} =
             author_conn |> post(~p"/api/articles", JSON.encode!(body)) |> json_response(201)

    assert %{"tagList" => [^a, ^b], "favorited" => false, "favoritesCount" => 0, "body" => "Carefully."} = created
    assert created["createdAt"] =~ @timestamp
    assert created["author"]["following"] == false

    assert %{"article" => ^created} = conn |> get(~p"/api/articles/#{slug}") |> json_response(200)

    assert %{"articles" => [listed], "articlesCount" => 1} = conn |> get(~p"/api/articles") |> json_response(200)
    refute Map.has_key?(listed, "body")
    assert listed["slug"] == slug

    assert %{"article" => %{"slug" => new_slug, "title" => "New"}} =
             author_conn |> put(~p"/api/articles/#{slug}", %{article: %{title: "New"}}) |> json_response(200)

    assert author_conn |> delete(~p"/api/articles/#{new_slug}") |> response(204) == ""
    assert conn |> get(~p"/api/articles/#{new_slug}") |> json_response(404)
  end

  test "a JSON body with the wrong types is a 422", %{author_conn: author_conn} do
    for article <- [
          %{title: 1, description: "d", body: "b"},
          %{title: "t", description: "d", body: "b", tagList: [1]},
          %{title: "t", description: "d", body: "b", tagList: "a"}
        ] do
      body = JSON.encode!(%{article: article})
      assert author_conn |> post(~p"/api/articles", body) |> json_response(422), body
    end
  end

  test "lists need valid paging", %{conn: conn} do
    for query <- ["limit=0", "limit=abc", "limit=", "offset=-1", "limit=%2B5"] do
      assert conn |> get("/api/articles?" <> query) |> json_response(422), query
    end
  end

  test "the feed needs a token", %{conn: conn} do
    assert conn |> get(~p"/api/articles/feed") |> json_response(401)
  end

  test "only the author may edit or delete", %{conn: conn, author: author} do
    article = article_fixture(author)
    other = authenticate(conn, user_fixture())

    assert other |> put(~p"/api/articles/#{article.slug}", %{article: %{title: "x"}}) |> json_response(403)
    assert other |> delete(~p"/api/articles/#{article.slug}") |> json_response(403)
  end

  test "favorites", %{conn: conn, author: author} do
    article = article_fixture(author)
    fan = authenticate(conn, user_fixture())

    assert %{"article" => %{"favorited" => true, "favoritesCount" => 1}} =
             fan |> post(~p"/api/articles/#{article.slug}/favorite") |> json_response(200)

    assert %{"article" => %{"favorited" => false, "favoritesCount" => 0}} =
             fan |> delete(~p"/api/articles/#{article.slug}/favorite") |> json_response(200)
  end

  test "comments", %{conn: conn, author: author, author_conn: author_conn} do
    article = article_fixture(author)

    assert %{"comment" => %{"id" => id, "body" => "Nice", "author" => %{"following" => false}} = comment} =
             author_conn
             |> post(~p"/api/articles/#{article.slug}/comments", %{comment: %{body: "Nice"}})
             |> json_response(201)

    assert comment["createdAt"] =~ @timestamp

    assert %{"comments" => [%{"id" => ^id}]} =
             conn |> get(~p"/api/articles/#{article.slug}/comments") |> json_response(200)

    assert author_conn |> delete(~p"/api/articles/#{article.slug}/comments/#{id}") |> response(204)
    assert author_conn |> delete(~p"/api/articles/#{article.slug}/comments/not-a-number") |> json_response(404)
  end

  test "an unknown route is a JSON 404", %{conn: conn} do
    assert %{"errors" => %{"body" => ["Not Found"]}} = conn |> get("/api/nope") |> json_response(404)
  end
end
