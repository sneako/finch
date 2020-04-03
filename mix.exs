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

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.0"},
      {:castore, "~> 0.1.5"},
      {:nimble_pool, github: "plataformatec/nimble_pool"},
      {:httparrot, "~> 1.2", only: :test}
    ]
  end
end
