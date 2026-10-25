defmodule Conduit.DataCase do
  @moduledoc "Tests that use the database, each inside a transaction that is rolled back afterwards."
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Conduit.DataCase
      import Conduit.Fixtures
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      alias Conduit.Repo
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Conduit.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc "A changeset's errors as `%{field: [message]}`, with interpolated messages."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
