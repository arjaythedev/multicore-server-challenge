defmodule Conduit.MixProject do
  use Mix.Project

  def project do
    [
      app: :conduit,
      version: "1.0.0",
      elixir: "~> 1.20",
      start_permanent: true,
      # the bcrypt NIF (native/, Makefile)
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps(),
      aliases: [test: "test --no-start"],
      # runtime_tools (msacc) and tools (tprof) are only loaded, never started: for profiling over `bin/conduit rpc`
      releases: [
        conduit: [
          include_executables_for: [:unix],
          strip_beams: true,
          applications: [runtime_tools: :load, tools: :load]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Conduit.Application, []}]
  end

  defp deps do
    [
      {:elixir_make, "== 0.10.0", runtime: false},
      # only for tests: the reference our own bcrypt is checked against
      {:bcrypt_elixir, "== 3.3.2", only: :test}
    ]
  end
end
