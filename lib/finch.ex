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
  Finch.start_link(name: MyFinch}
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
  `{scheme, host, port}`s that are known before starting Finch. When configuring
  pools, the `:size` is required. The `:count` will default to 1.

  ```elixir
  children = [
    {Finch,
     name: MyConfiguredFinch, 
     pools: %{
       :default => %{size: 10},
       {:https, "hex.pm", 443} => %{size: 32, count: 8}
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

  def start_link(opts) do
    name = Keyword.get(opts, :name) || raise ArgumentError, "must supply a name"
    pools = Keyword.get(opts, :pools, %{})

    config = %{
      registry_name: name,
      manager_name: manager_name(name),
      supervisor_name: pool_supervisor_name(name),
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

  defp supervisor_name(name), do: :"#{name}.Supervisor"
  defp manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"
end
