<img alt="Finch" height="350px" src="assets/Finch_logo_onWhite.png?raw=true">

[![Build Status](https://github.com/keathley/finch/workflows/CI/badge.svg?branch=master)](https://github.com/keathley/finch/actions) [![Hex pm](https://img.shields.io/hexpm/v/finch.svg?style=flat)](https://hex.pm/packages/finch)

<!-- MDOC !-->

An HTTP client with a focus on performance, built on top of
[Mint](https://github.com/elixir-mint/mint) and [NimblePool](https://github.com/dashbitco/nimble_pool).

## Usage

In order to use Finch, you must start it and provide a `:name`. Often in your
supervision tree:

```elixir
children = [
  {Finch, name: MyFinch}
]
```

Or, in rare cases, dynamically:

```elixir
Finch.start_link(name: MyFinch)
```

Once you have started your instance of Finch, you are ready to start making requests:

```elixir
Finch.build(:get, "https://hex.pm") |> Finch.request(MyFinch)
```

When using HTTP/1, Finch will parse the passed in URL into a `{scheme, host, port}`
tuple, and maintain one or more connection pools for each `{scheme, host, port}` you
interact with.

You can also configure a pool size and count to be used for specific URLs that are
known before starting Finch. The passed URLs will be parsed into `{scheme, host, port}`,
and the corresponding pools will be started. See `Finch.start_link/1` for configuration
options.

```elixir
children = [
  {Finch,
   name: MyConfiguredFinch,
   pools: %{
     :default => [size: 10],
     "https://hex.pm" => [size: 32, count: 8]
   }}
]
```

Pools will be started for each configured `{scheme, host, port}` when Finch is started.
For any unconfigured `{scheme, host, port}`, the pool will be started the first time
it is requested. Note pools are not automatically terminated if they are unused, so
Finch is best suited when you are requesting a known list of static hosts.

## Telemetry

Finch uses Telemetry to provide instrumentation. See the `Finch.Telemetry`
module for details on specific events.

<!-- MDOC !-->

## Installation

The package can be installed by adding `finch` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:finch, "~> 0.6"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/finch](https://hexdocs.pm/finch).
