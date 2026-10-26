defmodule Conduit.Db do
  @moduledoc false
  # Reads and writes go to separate connection pools: every commit waits for its WAL flush, and on a pipelined
  # connection every read queued behind a commit would wait for that flush too.
  # Errors are thrown as {:pg, sqlstate} or {:db_down, reason} for Conduit.Handler.

  def read(id, params), do: one(:read, id, params)

  @doc "A read whose rows stay raw DataRow column data, for Conduit.Render.Nif."
  def read_raw(id, params) do
    case Conduit.Pg.query_raw(:read, [{id, params}]) do
      {:ok, [rows]} -> rows
      error -> raise_error(error)
    end
  end

  def write(id, params), do: one(:write, id, params)

  @doc "Several write statements as one implicit transaction (one round trip): the rows of each, in order."
  def write_all(items) do
    case Conduit.Pg.query(:write, items) do
      {:ok, results} -> results
      error -> raise_error(error)
    end
  end

  defp one(pool, id, params) do
    case Conduit.Pg.query(pool, [{id, params}]) do
      {:ok, [rows]} -> rows
      error -> raise_error(error)
    end
  end

  defp raise_error({:error, {:pg, code}}), do: throw({:pg, code})
  defp raise_error({:error, other}), do: throw({:db_down, other})
end
