defmodule ConduitWeb.TagControllerTest do
  use ConduitWeb.ConnCase, async: true

  test "lists tags sorted by name", %{conn: conn} do
    [alpha, zeta] = [unique_tag("alpha"), unique_tag("zeta")]
    article_fixture(user_fixture(), %{"tag_list" => [zeta, alpha]})
    assert %{"tags" => [^alpha, ^zeta]} = conn |> get(~p"/api/tags") |> json_response(200)
  end
end
