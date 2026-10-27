defmodule Conduit.MixProject do
  use Mix.Project

  def project do
    [
      app: :conduit,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      releases: [conduit: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [mod: {Conduit.Application, []}, extra_applications: [:logger, :crypto, :runtime_tools]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.7"},
      {:bandit, "~> 1.13"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:joken, "~> 2.7"},
      {:bcrypt_elixir, "~> 3.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false}
    ]
  end

  # The schema is the challenge's ../../schema.sql, which the app must not change, so tests load it into a fresh
  # database instead of running migrations.
  defp aliases do
    [
      test: ["ecto.drop --quiet", "ecto.create --quiet", "ecto.load --quiet --dump-path ../../schema.sql", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
