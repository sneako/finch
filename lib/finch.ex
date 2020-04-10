defmodule Finch do
  @moduledoc """
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
  by passing the name of your client as the first argument of `Finch.request/3,4,5`:

  ```elixir
  Finch.request(MyFinch, :get, "https://hex.pm")
  ```

  When using HTTP/1, Finch will parse the passed in url into a `{scheme, host, port}`
  tuple, and maintain one or more connection pools for each `{scheme, host, port}` you
  interact with.

  You can also configure a pool size and count to be used for each specific
  `{scheme, host, port}`s that are known before starting Finch. See `Finch.start_link/1` for
  configuration options.

  ```elixir
  children = [
    {Finch,
     name: MyConfiguredFinch, 
     pools: %{
       :default => [size: 10],
       {:https, "hex.pm", 443} => [size: 32, count: 8, backoff: [initial: 1, max: 30_000]]
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
  """

  alias Finch.{Pool, PoolManager}

  use Supervisor

  @atom_methods [
    :get,
    :post,
    :put,
    :patch,
    :delete,
    :head,
    :options
  ]
  @methods [
    "GET",
    "POST",
    "PUT",
    "PATCH",
    "DELETE",
    "HEAD",
    "OPTIONS"
  ]
  @atom_to_method Enum.zip(@atom_methods, @methods) |> Enum.into(%{})

  @pool_config_schema [
    size: [
      type: :pos_integer,
      doc: "Number of connections to maintain in each pool.",
      default: 10
    ],
    count: [
      type: :pos_integer,
      doc: "Number of pools to start.",
      default: 1
    ],
    backoff: [
      type: :non_empty_keyword_list,
      default: [initial: 1, max: :timer.minutes(1)],
      doc:
        "Failed connection attempts will be retried using an exponential backoff with jitter. Values are in milliseconds.",
      keys: [
        initial: [
          type: :pos_integer,
          doc: "Backoff will begin at this value, and increase exponentially.",
          default: 1
        ],
        max: [
          type: :pos_integer,
          doc: "Backoff will be capped to this value.",
          default: :timer.minutes(1)
        ]
      ]
    ]
  ]

  @doc """
  Start an instance of Finch.

  ## Options:
    * `:name` - The name of your Finch instance. This field is required.

    * `:pools` - Configuration for your pools. You can provide a `:default` catch-all
    configuration for any non specfied {scheme, host, port}, or configuration for any
    specific {scheme, host, port}. See "Pool Configuration Options" below.

  ### Pool Configuration Options
  #{NimbleOptions.docs(@pool_config_schema)}
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name) || raise ArgumentError, "must supply a name"
    pools = Keyword.get(opts, :pools, []) |> pool_options!()
    {default_pool_config, pools} = Map.pop(pools, :default)

    config = %{
      registry_name: name,
      manager_name: manager_name(name),
      supervisor_name: pool_supervisor_name(name),
      default_pool_config: default_pool_config,
      pools: pools
    }

    Supervisor.start_link(__MODULE__, config, name: supervisor_name(name))
  end

  @impl true
  def init(config) do
    children = [
      {DynamicSupervisor, name: config.supervisor_name, strategy: :one_for_one},
      {Registry, [keys: :duplicate, name: config.registry_name, meta: [config: config]]},
      {PoolManager, config}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def request(name, method, url, headers \\ [], body \\ nil, opts \\ []) do
    uri = URI.parse(url)

    req = %{
      scheme: normalize_scheme(uri.scheme),
      host: uri.host,
      port: uri.port,
      method: build_method(method),
      path: uri.path || "/",
      headers: headers,
      body: body,
      query: uri.query
    }

    pool = PoolManager.get_pool(name, req.scheme, req.host, req.port)
    Pool.request(pool, req, opts)
  end

  defp build_method(method) when method in @methods, do: method

  defp build_method(method) when is_atom(method) do
    @atom_to_method[method]
  end

  defp normalize_scheme(scheme) do
    case scheme do
      "https" -> :https
      "http" -> :http
    end
  end

  defp pool_options!(pools) do
    {:ok, default} = NimbleOptions.validate([], @pool_config_schema)

    Enum.reduce(pools, %{default: valid_opts_to_map(default)}, fn {destination, opts}, acc ->
      case cast_pool_opts(opts) do
        {:ok, validated} ->
          Map.put(acc, destination, validated)

        {:error, reason} ->
          raise ArgumentError, "got invalid configuration for pool #{destination}! #{reason}"
      end
    end)
  end

  defp cast_pool_opts(opts) do
    with {:ok, valid} <- NimbleOptions.validate(opts, @pool_config_schema) do
      {:ok, valid_opts_to_map(valid)}
    end
  end

  defp valid_opts_to_map(valid) do
    %{
      size: valid[:size],
      count: valid[:count],
      backoff: Map.new(valid[:backoff]),
      conn_opts: []
    }
  end

  defp supervisor_name(name), do: :"#{name}.Supervisor"
  defp manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"
end
