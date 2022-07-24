defmodule Finch do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Finch.{PoolManager, Request, Response}

  use Supervisor

  @default_pool_size 50
  @default_pool_count 1

  @default_connect_timeout 5_000

  @pool_config_schema [
    protocol: [
      type: {:in, [:http2, :http1]},
      doc: "The type of connection and pool to use.",
      default: :http1
    ],
    size: [
      type: :pos_integer,
      doc: """
      Number of connections to maintain in each pool. Used only by HTTP1 pools \
      since HTTP2 is able to multiplex requests through a single connection. In \
      other words, for HTTP2, the size is always 1 and the `:count` should be \
      configured in order to increase capacity.
      """,
      default: @default_pool_size
    ],
    count: [
      type: :pos_integer,
      doc: """
      Number of pools to start. HTTP1 pools are able to re-use connections in the \
      same pool and establish new ones only when necessary. However, if there is a \
      high pool count and few requests are made, these requests will be scattered \
      across pools, reducing connection reuse. It is recommended to increase the pool \
      count for HTTP1 only if you are experiencing high checkout times.
      """,
      default: @default_pool_count
    ],
    max_idle_time: [
      type: :timeout,
      doc: """
      The maximum number of milliseconds an HTTP1 connection is allowed to be idle \
      before being closed during a checkout attempt.
      """,
      deprecated: "Use :conn_max_idle_time instead."
    ],
    conn_opts: [
      type: :keyword_list,
      doc: """
      These options are passed to `Mint.HTTP.connect/4` whenever a new connection is established. \
      `:mode` is not configurable as Finch must control this setting. Typically these options are \
      used to configure proxying, https settings, or connect timeouts.
      """,
      default: []
    ],
    pool_max_idle_time: [
      type: :timeout,
      doc: """
      The maximum number of milliseconds that a pool can be idle before being terminated, used only by HTTP1 pools. \
      This options is forwarded to NimblePool and it starts and idle verification cycle that may impact \
      performance if misused. For instance setting a very low timeout may lead to pool restarts. \
      For more information see NimblePool's `handle_ping/2` documentation.
      """,
      default: :infinity
    ],
    conn_max_idle_time: [
      type: :timeout,
      doc: """
      The maximum number of milliseconds an HTTP1 connection is allowed to be idle \
      before being closed during a checkout attempt.
      """,
      default: :infinity
    ]
  ]

  @typedoc """
  The `:name` provided to Finch in `start_link/1`.
  """
  @type name() :: atom()

  @typedoc """
  The stream function given to `stream/5`.
  """
  @type stream(acc) ::
          ({:status, integer} | {:headers, Mint.Types.headers()} | {:data, binary}, acc -> acc)

  @doc """
  Start an instance of Finch.

  ## Options

    * `:name` - The name of your Finch instance. This field is required.

    * `:pools` - A map specifying the configuration for your pools. The keys should be URLs
    provided as binaries, a tuple `{scheme, {:local, unix_socket}}` where `unix_socket` is the path for
    the socket, or the atom `:default` to provide a catch-all configuration to be used for any
    unspecified URLs. See "Pool Configuration Options" below for details on the possible map
    values. Default value is `%{default: [size: #{@default_pool_size}, count: #{@default_pool_count}]}`.

  ### Pool Configuration Options

  #{NimbleOptions.docs(@pool_config_schema)}
  """
  def start_link(opts) do
    name = finch_name!(opts)
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

  def child_spec(opts) do
    %{
      id: finch_name!(opts),
      start: {__MODULE__, :start_link, [opts]}
    }
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

  defp finch_name!(opts) do
    Keyword.get(opts, :name) || raise(ArgumentError, "must supply a name")
  end

  defp pool_options!(pools) do
    {:ok, default} = NimbleOptions.validate([], @pool_config_schema)

    Enum.reduce(pools, %{default: valid_opts_to_map(default)}, fn {destination, opts}, acc ->
      with {:ok, valid_destination} <- cast_destination(destination),
           {:ok, valid_pool_opts} <- cast_pool_opts(opts) do
        Map.put(acc, valid_destination, valid_pool_opts)
      else
        {:error, reason} ->
          raise reason
      end
    end)
  end

  defp cast_destination(destination) do
    case destination do
      :default ->
        {:ok, destination}

      {scheme, {:local, path}} when is_atom(scheme) and is_binary(path) ->
        {:ok, {scheme, {:local, path}, 0}}

      url when is_binary(url) ->
        cast_binary_destination(url)

      _ ->
        {:error, %ArgumentError{message: "invalid destination: #{inspect(destination)}"}}
    end
  end

  defp cast_binary_destination(url) when is_binary(url) do
    {scheme, host, port, _path, _query} = Finch.Request.parse_url(url)
    {:ok, {scheme, host, port}}
  end

  defp cast_pool_opts(opts) do
    with {:ok, valid} <- NimbleOptions.validate(opts, @pool_config_schema) do
      {:ok, valid_opts_to_map(valid)}
    end
  end

  defp valid_opts_to_map(valid) do
    # We need to enable keepalive and set the nodelay flag to true by default.
    transport_opts =
      valid
      |> get_in([:conn_opts, :transport_opts])
      |> List.wrap()
      |> Keyword.put_new(:timeout, @default_connect_timeout)
      |> Keyword.put_new(:nodelay, true)
      |> Keyword.put(:keepalive, true)

    conn_opts = valid[:conn_opts] |> List.wrap()

    ssl_key_log_file =
      Keyword.get(conn_opts, :ssl_key_log_file) || System.get_env("SSLKEYLOGFILE")

    ssl_key_log_file_device = ssl_key_log_file && File.open!(ssl_key_log_file, [:append])

    conn_opts =
      conn_opts
      |> Keyword.put(:ssl_key_log_file_device, ssl_key_log_file_device)
      |> Keyword.put(:transport_opts, transport_opts)

    %{
      size: valid[:size],
      count: valid[:count],
      conn_opts: conn_opts,
      protocol: valid[:protocol],
      conn_max_idle_time: to_native(valid[:max_idle_time] || valid[:conn_max_idle_time]),
      pool_max_idle_time: valid[:pool_max_idle_time]
    }
  end

  defp to_native(:infinity), do: :infinity
  defp to_native(time), do: System.convert_time_unit(time, :millisecond, :native)

  defp supervisor_name(name), do: :"#{name}.Supervisor"
  defp manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"

  defmacrop request_span(request, name, do: block) do
    quote do
      start_meta = %{request: unquote(request), name: unquote(name)}

      Finch.Telemetry.span(:request, start_meta, fn ->
        result = unquote(block)
        end_meta = Map.put(start_meta, :result, result)
        {result, end_meta}
      end)
    end
  end

  @doc """
  Builds an HTTP request to be sent with `request/3` or `stream/4`.

  It is possible to send the request body in a streaming fashion. In order to do so, the
  `body` parameter needs to take form of a tuple `{:stream, body_stream}`, where `body_stream`
  is a `Stream`.
  """
  @spec build(Request.method(), Request.url(), Request.headers(), Request.body(), Keyword.t()) ::
          Request.t()
  defdelegate build(method, url, headers \\ [], body \\ nil, opts \\ []), to: Request

  @doc """
  Streams an HTTP request and returns the accumulator.

  A function of arity 2 is expected as argument. The first argument
  is a tuple, as listed below, and the second argument is the
  accumulator. The function must return a potentially updated
  accumulator.

  ## Stream commands

    * `{:status, status}` - the status of the http response
    * `{:headers, headers}` - the headers of the http response
    * `{:data, data}` - a streaming section of the http body

  ## Options

    * `:pool_timeout` - This timeout is applied when we check out a connection from the pool.
      Default value is `5_000`.

    * `:receive_timeout` - The maximum time to wait for a response before returning an error.
      Default value is `15_000`.

  """
  @spec stream(Request.t(), name(), acc, stream(acc), keyword) ::
          {:ok, acc} | {:error, Exception.t()}
        when acc: term()
  def stream(%Request{} = req, name, acc, fun, opts \\ []) when is_function(fun, 2) do
    request_span req, name do
      __stream__(req, name, acc, fun, opts)
    end
  end

  defp __stream__(%Request{} = req, name, acc, fun, opts) when is_function(fun, 2) do
    shp = build_shp(req)
    {pool, pool_mod} = PoolManager.get_pool(name, shp)
    pool_mod.request(pool, req, acc, fun, opts)
  end

  defp build_shp(%Request{scheme: scheme, unix_socket: unix_socket})
       when is_binary(unix_socket) do
    {scheme, {:local, unix_socket}, 0}
  end

  defp build_shp(%Request{scheme: scheme, host: host, port: port}) do
    {scheme, host, port}
  end

  @doc """
  Sends an HTTP request and returns a `Finch.Response` struct.

  ## Options

    * `:pool_timeout` - This timeout is applied when we check out a connection from the pool.
      Default value is `5_000`.

    * `:receive_timeout` - The maximum time to wait for a response before returning an error.
      Default value is `15_000`.

  """
  @spec request(Request.t(), name(), keyword()) ::
          {:ok, Response.t()}
          | {:error, Exception.t()}
  def request(req, name, opts \\ [])

  def request(%Request{} = req, name, opts) do
    request_span req, name do
      acc = {nil, [], []}

      fun = fn
        {:status, value}, {_, headers, body} -> {value, headers, body}
        {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, value}, {status, headers, body} -> {status, headers, [value | body]}
      end

      with {:ok, {status, headers, body}} <- __stream__(req, name, acc, fun, opts) do
        {:ok,
         %Response{
           status: status,
           headers: headers,
           body: body |> Enum.reverse() |> IO.iodata_to_binary()
         }}
      end
    end
  end

  # Catch-all for backwards compatibility below
  def request(name, method, url) do
    request(name, method, url, [])
  end

  @doc false
  def request(name, method, url, headers, body \\ nil, opts \\ []) do
    IO.warn("Finch.request/6 is deprecated, use Finch.build/5 + Finch.request/3 instead")

    build(method, url, headers, body)
    |> request(name, opts)
  end
end
