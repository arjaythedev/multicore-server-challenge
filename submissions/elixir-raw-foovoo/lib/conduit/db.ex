defmodule Conduit.Db do
  @moduledoc false
  # Each statement is parsed once per pooled connection (`cache_statement`) and then costs one Bind/Execute/Sync
  # round trip. Reads and writes share one pool: a split pool leaves one side's connections idle while the other side
  # queues, and writes are ~5% of requests.
  alias Conduit.Sql

  def read(id, params), do: run(id, params)
  def write(id, params), do: run(id, params)

  @doc "Runs `fun` in a transaction; `fun` gets a connection for `q/3`."
  def transaction(fun) do
    case Postgrex.transaction(Conduit.Pg, fun, timeout: 15_000) do
      {:ok, value} -> value
      {:error, {:pg, code}} -> throw({:pg, code})
      {:error, other} -> throw({:db_down, other})
    end
  end

  @doc "Inside `transaction/1`: rolls the transaction back on a Postgres error."
  def q(conn, id, params) do
    {name, sql} = Sql.get(id)

    case Postgrex.query(conn, sql, params, cache_statement: name) do
      {:ok, %Postgrex.Result{rows: rows}} -> rows
      {:error, %Postgrex.Error{postgres: %{pg_code: code}}} -> Postgrex.rollback(conn, {:pg, code})
      {:error, other} -> Postgrex.rollback(conn, {:db_down, other})
    end
  end

  defp run(id, params) do
    {name, sql} = Sql.get(id)

    case Postgrex.query(Conduit.Pg, sql, params, cache_statement: name) do
      {:ok, %Postgrex.Result{rows: rows}} -> rows
      {:error, %Postgrex.Error{postgres: %{pg_code: code}}} -> throw({:pg, code})
      {:error, other} -> throw({:db_down, other})
    end
  end
end
