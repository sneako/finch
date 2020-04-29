defmodule Finch do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

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
  @pool_selection_strategies [:random, :round_robin]

  @pool_config_schema [
    size: [
      type: :pos_integer,
      doc: "Number of connections to maintain in each pool.",
      default: @default_pool_size
    ],
    count: [
      type: :pos_integer,
      doc: "Number of pools to start.",
      default: @default_pool_count
    ],
    conn_opts: [
      type: :keyword_list,
      doc: """
      These options are passed to `Mint.HTTP.connect/4` whenever a new connection is established.
      `:mode` is not configurable as Finch must control this setting.
      Typically these options are used to configure proxying, https settings, or connect timeouts.
      """,
      default: []
    ],
    strategy: [
      type: {:one_of, @pool_selection_strategies},
      doc: """
      How requests will be routed to your pools. Only relevant when count > 1.
      The following options are available: `#{
        Enum.map_join(@pool_selection_strategies, "`, `", &inspect/1)
      }`
      """,
      default: :random
    ]
  ]

  @typedoc """
  The `:name` provided to Finch in `start_link/1`.
  """
  @type name() :: atom()

  @typedoc """
  An HTTP request method represented as an `atom()` or a `String.t()`.

  The following atom methods are supported: `#{Enum.map_join(@atom_methods, "`, `", &inspect/1)}`.
  You can use any arbitrary method by providing it as a `String.t()`.
  """
  @type http_method() :: :get | :post | :put | :patch | :delete | :head | :options | String.t()

  @typedoc """
  A Uniform Resource Locator, the address of a resource on the Web.
  """
  @type url() :: String.t()

  @typedoc """
  A body associated with a request.
  """
  @type body() :: iodata() | nil

  @doc """
  Start an instance of Finch.

  ## Options:
    * `:name` - The name of your Finch instance. This field is required.

    * `:pools` - A map specifying the configuration for your pools. The keys should be URLs 
    provided as binaries, or the atom `:default` to provide a catch-all configuration to be used
    for any unspecified URLs. See "Pool Configuration Options" below for details on the possible
    map values. Default value is `%{default: [size: #{@default_pool_size}, count: #{
    @default_pool_count
  }]}`.

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

  @doc """
  Sends an HTTP request and returns the response.

  ## Options:

    * `:pool_timeout` - This timeout is applied when we check out a connection from the pool.
      Default value is `5_000`.

    * `:receive_timeout` - The maximum time to wait for a response before returning an error.
      Default value is `15_000`.
  """
  @spec request(name(), http_method(), url(), Mint.Types.headers(), body(), keyword()) ::
          {:ok, Finch.Response.t()} | {:error, Mint.Types.error()}
  def request(name, method, url, headers \\ [], body \\ nil, opts \\ []) do
    with {:ok, uri} <- parse_and_normalize_url(url) do
      req = %{
        scheme: uri.scheme,
        host: uri.host,
        port: uri.port,
        method: build_method(method),
        path: uri.path,
        headers: headers,
        body: body,
        query: uri.query
      }

      shp = {uri.scheme, uri.host, uri.port}

      pool = PoolManager.get_pool(name, shp)
      Pool.request(pool, req, opts)
    end
  end

  defp parse_and_normalize_url(url) when is_binary(url) do
    parsed_uri = URI.parse(url)
    normalized_path = parsed_uri.path || "/"

    with {:ok, scheme} <- normalize_scheme(parsed_uri.scheme) do
      normalized_uri = %{
        scheme: scheme,
        host: parsed_uri.host,
        port: parsed_uri.port,
        path: normalized_path,
        query: parsed_uri.query
      }

      {:ok, normalized_uri}
    end
  end

  defp build_method(method) when is_binary(method), do: method
  defp build_method(method) when method in @atom_methods, do: @atom_to_method[method]

  defp build_method(method) do
    raise ArgumentError, """
    got unsupported atom method #{inspect(method)}.
    only the following methods can be provided as atoms: #{
      Enum.map_join(@atom_methods, ", ", &inspect/1)
    }",
    otherwise you must pass a binary.
    """
  end

  defp normalize_scheme(scheme) do
    case scheme do
      "https" ->
        {:ok, :https}

      "http" ->
        {:ok, :http}

      scheme ->
        {:error, "invalid scheme #{inspect(scheme)}"}
    end
  end

  defp pool_options!(pools) do
    {:ok, default} = NimbleOptions.validate([], @pool_config_schema)

    Enum.reduce(pools, %{default: valid_opts_to_map(default)}, fn {destination, opts}, acc ->
      with {:ok, valid_destination} <- cast_destination(destination),
           {:ok, valid_pool_opts} <- cast_pool_opts(opts) do
        Map.put(acc, valid_destination, valid_pool_opts)
      else
        {:error, reason} ->
          raise ArgumentError,
                "got invalid configuration for pool #{inspect(destination)}! #{reason}"
      end
    end)
  end

  defp cast_destination(destination) do
    case destination do
      :default ->
        {:ok, destination}

      url when is_binary(url) ->
        cast_binary_destination(url)

      _ ->
        {:error, "invalid destination"}
    end
  end

  defp cast_binary_destination(url) when is_binary(url) do
    with {:ok, uri} <- parse_and_normalize_url(url),
         shp <- {uri.scheme, uri.host, uri.port} do
      {:ok, shp}
    end
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
      strategy: pool_strategy(valid[:strategy]),
      conn_opts: valid[:conn_opts]
    }
  end

  defp supervisor_name(name), do: :"#{name}.Supervisor"
  defp manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"

  defp pool_strategy(type) do
    case type do
      :round_robin -> Pool.RoundRobin
      :random -> Pool.Random
    end
  end
end
