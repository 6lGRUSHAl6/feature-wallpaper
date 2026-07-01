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

  def application do
    [
      extra_applications: [:logger],
      mod: {FW.Application, []}
    ]
  end

  defp deps do
    []
  end

  defp releases do
    [
      fw: [
        include_executables_for: [:unix],
        # InitUnits runs after :assemble (binary exists) and before :tar
        # (so unit files are included in the release tarball).
        steps: [:assemble, &FW.Release.InitUnits.run/1, :tar]
      ]
    ]
  end
end
