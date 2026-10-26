defmodule Conduit.MixProject do
  use Mix.Project

  # No dependencies: the HTTP server, the Postgres client, JWT and JSON output are all in lib/, JSON input is OTP's
  # :json, and bcrypt is a small NIF in c_src/ (built by build.sh).
  def project do
    [
      app: :conduit,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: true,
      deps: [],
      aliases: [test: "test --no-start"],
      releases: [conduit: [include_executables_for: [:unix], strip_beams: true]]
    ]
  end

  def application do
    [extra_applications: [:crypto], mod: {Conduit.Application, []}]
  end
end
