defmodule LoggerJSON.Mixfile do
  use Mix.Project

  @source_url "https://github.com/Nebo15/logger_json"
  @version "4.2.0"

  def project do
    [
      app: :logger_json,
      version: @version,
      elixir: "~> 1.8",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [] ++ Mix.compilers(),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.travis": :test, "coveralls.html": :test],
      dialyzer: [
        plt_add_apps: [:plug]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.0"},
      {:ecto, "~> 2.1 or ~> 3.0", optional: true},
      {:plug, "~> 1.0", optional: true},
      {:telemetry, "~> 0.4.0", optional: true},
      {:ex_doc, ">= 0.15.0", only: [:dev, :test], runtime: false},
      {:excoveralls, ">= 0.5.0", only: [:dev, :test]},
      {:dialyxir, "~> 1.1.0", only: [:dev], runtime: false},
      {:stream_data, "~> 0.5", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      description:
        "Console Logger back-end, Plug and Ecto adapter " <>
          "that writes logs in JSON format.",
      contributors: ["Nebo #15"],
      maintainers: ["Nebo #15"],
      licenses: ["MIT"],
      files: ~w(lib LICENSE.md mix.exs README.md),
      links: %{
        Changelog: "https://hexdocs.pm/logger_json/changelog.html",
        GitHub: @source_url
      }
    ]
  end

  defp docs do
    [
      extras: [
        "LICENSE.md": [title: "License"],
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end
end
