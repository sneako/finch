![Finch](./assets/Finch_logo_onWhite.png#gh-light-mode-only)
![Finch](./assets/Finch_logo_all-White.png#gh-dark-mode-only)

[![Build Status](https://github.com/sneako/finch/workflows/CI/badge.svg?branch=main)](https://github.com/sneako/finch/actions) [![Hex pm](https://img.shields.io/hexpm/v/finch.svg?style=flat)](https://hex.pm/packages/finch) [![Hexdocs.pm](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/finch/)

<!-- MDOC !-->

An HTTP client with a focus on performance, built on top of
[Mint](https://github.com/elixir-mint/mint) and [NimblePool](https://github.com/dashbitco/nimble_pool).

We try to achieve this goal by providing efficient connection pooling strategies and avoiding copying wherever possible.

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
it is requested. Note pools are not automatically terminated by default, if you need to
terminate them after some idle time, use the `pool_max_idle_time` option (available only for HTTP1 pools).

## Telemetry

Finch uses Telemetry to provide instrumentation. See the `Finch.Telemetry`
module for details on specific events.

## Logging TLS Secrets

Finch supports logging TLS secrets to a file. These can be later used in a tool such as
Wireshark to decrypt HTTPS sessions. To use this feature you must specify the file to
which the secrets should be written. If you are using TLSv1.3 you must also add
`keep_secrets: true` to your pool `:transport_opts`. For example:

```elixir
{Finch,
 name: MyFinch,
 pools: %{
   default: [conn_opts: [transport_opts: [keep_secrets: true]]]
 }}
```

There are two different ways to specify this file:

1. The `:ssl_key_log_file` connection option in your pool configuration. For example:

```elixir
{Finch,
 name: MyFinch,
 pools: %{
   default: [
     conn_opts: [
       ssl_key_log_file: "/writable/path/to/the/sslkey.log"
     ]
   ]
 }}
```

2. Alternatively, you could also set the `SSLKEYLOGFILE` environment variable.

<!-- MDOC !-->

## Installation

The package can be installed by adding `finch` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:finch, "~> 0.15"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/finch](https://hexdocs.pm/finch).
