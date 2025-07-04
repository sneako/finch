defmodule Finch.MixProject do
  use Mix.Project

  @name "Finch"
  @version "0.20.0"
  @repo_url "https://github.com/sneako/finch"

  def project do
    [
      app: :finch,
      version: @version,
      elixir: "~> 1.13",
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
  defp elixirc_paths(:dev), do: ["lib", "test/support/test_usage.ex"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.6.2 or ~> 1.7"},
      {:nimble_pool, "~> 1.1"},
      {:nimble_options, "~> 0.4 or ~> 1.0"},
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:mime, "~> 1.0 or ~> 2.0"},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:credo, "~> 1.3", only: [:dev, :test]},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:bypass, "~> 2.0", only: :test},
      {:cowboy, "~> 2.7", only: [:dev, :test]},
      {:plug_cowboy, "~> 2.0", only: [:dev, :test]},
      {:x509, "~> 0.8", only: [:dev, :test]},
      {:mimic, "~> 1.7", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @repo_url,
        "Changelog" => "https://hexdocs.pm/finch/changelog.html"
      }
    ]
  end

  defp docs do
    [
      logo: "assets/Finch_logo_all-White.png",
      source_ref: "v#{@version}",
      source_url: @repo_url,
      main: @name,
      extras: [
        "CHANGELOG.md"
      ]
    ]
  end
end
