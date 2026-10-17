defmodule Conduit.MixProject do
  use Mix.Project

  def project do
    [
      app: :conduit,
      version: "1.0.0",
      elixir: "~> 1.19",
      start_permanent: true,
      deps: deps(),
      aliases: [test: "test --no-start"],
      releases: [conduit: [include_executables_for: [:unix], strip_beams: true]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Conduit.Application, []}]
  end

  defp deps do
    [
      {:postgrex, "== 0.22.4"},
      {:bcrypt_elixir, "== 3.3.2"}
    ]
  end
end
