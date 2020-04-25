# Finch

<!-- MDOC !-->

An HTTP client with a focus on performance.

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

Once you have started Finch, you can use the client you have started,
by passing the name of your client as the first argument of `Finch.request/3,4,5,6`:

```elixir
Finch.request(MyFinch, :get, "https://hex.pm")
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

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `finch` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:finch, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/finch](https://hexdocs.pm/finch).
