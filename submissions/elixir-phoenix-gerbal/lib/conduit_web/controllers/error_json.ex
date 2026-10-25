defmodule ConduitWeb.ErrorJSON do
  @moduledoc ~s(Error bodies, in RealWorld's `{"errors": {"body": [...]}}` shape.)

  def error(%{message: message}), do: %{errors: %{body: [message]}}

  # Errors Phoenix renders itself (no route, crashes), by status template: "404.json", "500.json", ...
  def render(template, _assigns) do
    error(%{message: Phoenix.Controller.status_message_from_template(template)})
  end
end
