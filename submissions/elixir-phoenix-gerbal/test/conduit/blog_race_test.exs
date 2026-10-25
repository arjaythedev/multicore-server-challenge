defmodule Conduit.BlogRaceTest do
  # Not async: the triggers lock their tables until the test's transaction rolls back.
  use Conduit.DataCase, async: false

  alias Conduit.Blog

  # A write that reads a row first can lose a race with a request that deletes it. A trigger, rolled back with the
  # test, makes every write lose: run before `event` on `table`, its `body` deletes the article under a new row (whose
  # insert then breaks the foreign key), or skips the row (as a concurrent delete leaves nothing to change or delete).
  defp lose_race(event, table, body) do
    Repo.query!("CREATE FUNCTION lose_race() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN #{body} END $$")
    Repo.query!("CREATE TRIGGER lose_race BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION lose_race()")
  end

  setup do
    author = user_fixture()
    %{author: author, reader: user_fixture(), article: article_fixture(author)}
  end

  # A favorite's lookup and insert are one statement, locked against a concurrent delete: see BlogLockTest.

  test "commenting on an article deleted meanwhile is a 404", %{reader: reader, article: article} do
    lose_race("INSERT", "comments", "DELETE FROM articles WHERE id = NEW.article_id; RETURN NEW;")
    assert {:error, :not_found} = Blog.create_comment(article.slug, reader.id, %{"body" => "hi"})
  end

  test "editing an article deleted meanwhile is a 404", %{author: author, article: article} do
    lose_race("UPDATE", "articles", "RETURN NULL;")
    assert {:error, :not_found} = Blog.update_article(article.slug, author.id, %{"title" => "New"})
  end

  # SPEC.md checks only that the article or comment exists before its DELETE, so a delete that finds it gone is a 204.
  test "deleting an article deleted meanwhile is fine", %{author: author, article: article} do
    lose_race("DELETE", "articles", "RETURN NULL;")
    assert :ok = Blog.delete_article(article.slug, author.id)
  end

  test "an invalid edit stays a changeset, not mistaken for a lost race", %{author: author, article: article} do
    lose_race("UPDATE", "articles", "RETURN NULL;")
    assert {:error, %Ecto.Changeset{}} = Blog.update_article(article.slug, author.id, %{"title" => ""})
  end

  test "deleting a comment deleted meanwhile is fine", %{reader: reader, article: article} do
    {:ok, comment} = Blog.create_comment(article.slug, reader.id, %{"body" => "hi"})
    lose_race("DELETE", "comments", "RETURN NULL;")
    assert :ok = Blog.delete_comment(article.slug, Integer.to_string(comment.id), reader.id)
  end
end
