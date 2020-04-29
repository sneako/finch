defmodule Finch.MixProject do
  use Mix.Project

  @name "Finch"
  @version "0.1.0"
  @repo_url "https://github.com/keathley/finch"

  def project do
    [
      app: :finch,
      version: @version,
      elixir: "~> 1.7",
      description: "An HTTP client focused on performance.",
      package: package(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      name: @name,
      source_url: @repo_url,
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
      # {:nimble_pool, "~> 0.1.0"},
      {:nimble_pool, github: "dashbitco/nimble_pool"},
      {:nimble_options, "~> 0.2.0"},
      {:telemetry, "~> 0.4.0"},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:credo, "~> 1.3", only: [:dev, :test]},
      {:bypass, "~> 1.0", only: :test}
    ]
  end

  def package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @repo_url}
    ]
  end

  def docs do
    [
      source_ref: "v#{@version}",
      source_url: @repo_url,
      main: @name
    ]
  end
end
