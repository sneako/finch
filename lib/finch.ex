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

  @default_pool_size 10
  @default_pool_count 1
  @default_backoff_initial 1
  @default_backoff_max :timer.minutes(1)

  @doc """
  ## Options:
    * `:name` - The name of your Finch instance. This field is required.

    * `:pools` - Configuration for your pools. You can provide a `:default` catch-all
    configuration for any non specfied {scheme, host, port}, or configuration for any
    specific {scheme, host, port}. See "Pool Configuration Options" below.

  ### Pool Configuration Options
    * `:size` - Number of connections to maintain in each pool.
    The default value is `#{@default_pool_size}`.

    * `:count` - Number of pools to start The default value is `#{@default_pool_count}`.

    * `:backoff` - Failed connection attempts will be retried using an exponential backoff with jitter.
    Backoff configuration should include the following keys:

      * `:initial` - Backoff will begin at this value, and increase exponentially.
      The default value is `#{@default_backoff_initial}`.

      * `:max` - Backoff will be capped to this value.
      The default value is `#{@default_backoff_max}`.
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

  def pool_options!(pools) do
    Enum.reduce(pools, %{default: default_pool_options()}, fn {destination, opts}, acc ->
      case cast_pool_opts(opts) do
        {:ok, validated} ->
          Map.put(acc, destination, validated)

        {:error, reason} ->
          raise ArgumentError, "got invalid configuration for pool #{destination}! #{reason}"
      end
    end)
  end

  defp cast_pool_opts(opts) do
    with {:ok, size} <- validate_pool_size(opts),
         {:ok, count} <- validate_pool_count(opts),
         {:ok, backoff} <- validate_backoff(opts[:backoff]) do
      {:ok, %{size: size, count: count, backoff: backoff, conn_opts: []}}
    end
  end

  defp validate_pool_size(opts) do
    opts |> Keyword.get(:size, @default_pool_size) |> validate_pos_integer()
  end

  defp validate_pool_count(opts) do
    opts |> Keyword.get(:count, @default_pool_size) |> validate_pos_integer()
  end

  defp validate_backoff(nil) do
    {:ok, %{initial: @default_backoff_initial, max: @default_backoff_max}}
  end

  defp validate_backoff(opts) do
    init = Keyword.get(opts, :initial, @default_backoff_initial)
    max = Keyword.get(opts, :initial, @default_backoff_max)

    with {:ok, init} <- validate_pos_integer(init),
         {:ok, max} <- validate_pos_integer(max) do
      {:ok, %{initial: init, max: max}}
    end
  end

  defp validate_pos_integer(val) when is_integer(val) and val > 0, do: {:ok, val}
  defp validate_pos_integer(val), do: {:error, "expected a positive integer, got #{inspect(val)}"}

  defp default_pool_options do
    backoff = %{initial: @default_backoff_initial, max: @default_backoff_max}
    %{size: @default_pool_size, count: @default_pool_count, backoff: backoff, conn_opts: []}
  end

  defp supervisor_name(name), do: :"#{name}.Supervisor"
  defp manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"
end
