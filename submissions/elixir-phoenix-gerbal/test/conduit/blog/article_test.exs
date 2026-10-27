defmodule Conduit.Blog.ArticleTest do
  use ExUnit.Case, async: true

  alias Conduit.Blog.Article

  describe "slug/2" do
    test "matches SPEC.md's SLUGIFY" do
      assert Article.slug("Hello, World!", 7) == "hello-world-7"
      assert Article.slug("  --Ünïcödé  tïtle--  ", 1) == "n-c-d-t-tle-1"
      assert Article.slug("!!!", 3) == "-3"
    end
  end

  describe "create_changeset/2" do
    @valid %{"title" => "t", "description" => "d", "body" => "b"}

    test "requires title, description and body" do
      changeset = Article.create_changeset(%Article{}, %{"title" => "", "body" => 1})
      refute changeset.valid?
      assert changeset.errors |> Keyword.keys() |> Enum.sort() == [:body, :description, :title]
    end

    test "takes values of only whitespace, which are not empty" do
      assert Article.create_changeset(%Article{}, %{"title" => " ", "description" => "\t", "body" => "\n"}).valid?
    end

    test "rejects blank and non-string tags" do
      for tags <- [["ok", ""], [nil], [1], "x"] do
        refute Article.create_changeset(%Article{}, Map.put(@valid, "tag_list", tags)).valid?, inspect(tags)
      end
    end

    test "allows no tags" do
      assert Article.create_changeset(%Article{}, Map.put(@valid, "tag_list", nil)).valid?
      assert Article.create_changeset(%Article{}, Map.put(@valid, "tag_list", [])).valid?
      assert Article.create_changeset(%Article{}, @valid).valid?
    end
  end
end
