defmodule FW.MixProject do
  use Mix.Project

  def project do
    [
      app: :fw,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers() ++ [:fw_renderer],
      releases: releases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {FW.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
    ]
  end

  defp releases do
    [
      fw: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
