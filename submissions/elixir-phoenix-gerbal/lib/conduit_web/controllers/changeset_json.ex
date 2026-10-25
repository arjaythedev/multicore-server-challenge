defmodule ConduitWeb.ChangesetJSON do
  @moduledoc "Changeset errors as a list of messages such as `\"email has already been taken\"`."

  def error(%{changeset: changeset}) do
    messages =
      for {field, errors} <- Ecto.Changeset.traverse_errors(changeset, &translate_error/1),
          message <- errors,
          do: "#{field} #{message}"

    %{errors: %{body: messages}}
  end

  defp translate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
