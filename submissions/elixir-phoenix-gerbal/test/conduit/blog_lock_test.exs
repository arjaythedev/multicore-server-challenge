defmodule Conduit.BlogLockTest do
  # Two real connections, outside the sandbox: a delete in one only shows in the other once it commits. Not async: the
  # rows are committed, and removed again after each test.
  use ExUnit.Case, async: false

  import Conduit.Fixtures
  import Ecto.Query

  alias Conduit.Accounts.User
  alias Conduit.Blog
  alias Conduit.Blog.Article
  alias Conduit.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    {author, reader, article} =
      Sandbox.unboxed_run(Repo, fn ->
        author = user_fixture()
        {author, user_fixture(), article_fixture(author)}
      end)

    on_exit(fn ->
      users = from u in User, where: u.id in ^[author.id, reader.id]
      Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(users) end)
    end)

    %{reader: reader, article: article}
  end

  test "favoriting an article being deleted waits for the delete, then is a 404", %{reader: reader, article: article} do
    test = self()

    deleter =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transact(fn ->
            query = from a in Article, where: a.id == ^article.id
            Repo.delete_all(query)
            send(test, :deleted)

            receive do
              :commit -> {:ok, :committed}
            end
          end)
        end)
      end)

    assert_receive :deleted
    favorite = Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> Blog.favorite_article(article.slug, reader.id) end) end)
    await_lock_wait(~s(INSERT INTO "favorites"%))
    send(deleter.pid, :commit)

    assert {:ok, :committed} = Task.await(deleter)
    assert {:error, :not_found} = Task.await(favorite)
  end

  # Waits until a backend running a statement like `pattern` is blocked on a lock.
  defp await_lock_wait(pattern, attempts \\ 200) do
    query = "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE $1"
    %{rows: [[waiting]]} = Sandbox.unboxed_run(Repo, fn -> Repo.query!(query, [pattern]) end)

    cond do
      waiting > 0 ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        await_lock_wait(pattern, attempts - 1)

      true ->
        flunk("no statement like #{pattern} waited on a lock")
    end
  end
end
