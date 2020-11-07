defmodule Finch.MixProject do
  use Mix.Project

  @name "Finch"
  @version "0.5.1"
  @repo_url "https://github.com/keathley/finch"

  def project do
    [
      app: :finch,
      version: @version,
      elixir: "~> 1.7",
      description: "An HTTP client focused on performance.",
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      name: @name,
      source_url: @repo_url,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.2"},
      {:castore, "~> 0.1.5"},
      {:nimble_pool, "~> 0.2.3"},
      {:nimble_options, "~> 0.3.4"},
      {:telemetry, "~> 0.4"},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:credo, "~> 1.3", only: [:dev, :test]},
      {:bypass, "~> 1.0", only: :test},
      {:cowboy, "~> 2.0", only: [:dev, :test]},
      {:plug_cowboy, "~> 2.0", only: [:dev, :test]},
      {:x509, "~> 0.8", only: [:dev, :test]}
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
      logo: "assets/Finch_logo_all-White.png",
      source_ref: "v#{@version}",
      source_url: @repo_url,
      main: @name
    ]
  end
end
