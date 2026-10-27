defmodule Conduit.Repo do
  use Ecto.Repo, otp_app: :conduit, adapter: Ecto.Adapters.Postgres
end
