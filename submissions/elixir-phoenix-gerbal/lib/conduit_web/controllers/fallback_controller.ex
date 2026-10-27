defmodule ConduitWeb.FallbackController do
  @moduledoc """
  Turns a controller's `{:error, reason}` into the API's error response.

  It renders with `json/2` rather than templates because the plugs that halt early (body parsing, authentication)
  call it before the router has negotiated a format.
  """
  use Phoenix.Controller, formats: [:json]

  alias ConduitWeb.ChangesetJSON
  alias ConduitWeb.ErrorJSON

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ChangesetJSON.error(%{changeset: changeset}))
  end

  def call(conn, {:error, reason}) do
    {status, message} = status_and_message(reason)

    conn
    |> put_status(status)
    |> json(ErrorJSON.error(%{message: message}))
  end

  defp status_and_message(:invalid_body), do: {:unprocessable_entity, "request body is not valid"}
  defp status_and_message(:unauthorized), do: {:unauthorized, "unauthorized"}
  defp status_and_message(:forbidden), do: {:forbidden, "forbidden"}
  defp status_and_message(:not_found), do: {:not_found, "not found"}
end
