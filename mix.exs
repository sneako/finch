defmodule Finch.MixProject do
  use Mix.Project

  def project do
    [
      app: :finch,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Finch.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mint, "~> 1.0"},
      {:castore, "~> 0.1.3"},
      {:nimble_pool, github: "plataformatec/nimble_pool"},
      {:cowboy, "~> 2.0"},
      {:plug_cowboy, "~> 2.0"},

      {:x509, "~> 0.8", only: [:dev, :test]},
    ]
  end
end
