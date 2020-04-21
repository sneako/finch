defmodule Finch.MixProject do
  use Mix.Project

  def project do
    [
      app: :finch,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.0"},
      {:castore, "~> 0.1.5"},
      {:nimble_pool, github: "dashbitco/nimble_pool"},
      {:nimble_options, github: "dashbitco/nimble_options"},
      {:telemetry, "~> 0.4"},
      {:backoff, "~> 1.1"},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:credo, "~> 1.3", only: [:dev, :test]},
      {:bypass, "~> 1.0", only: :test}
    ]
  end
end
