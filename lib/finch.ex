defmodule Finch do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Finch.{Pool, Request, Response}
  require Finch.Pool.Manager

  use Supervisor

  @default_pool_size 50
  @default_pool_count 1

  @default_connect_timeout 5_000

  @pool_config_schema [
    protocols: [
      type: {:list, {:in, [:http1, :http2]}},
      doc: """
      The type of connections to support.

      If using `:http1` only, an HTTP1 pool without multiplexing is used. \
      If using `:http2` only, an HTTP2 pool with multiplexing is used. \
      If both are listed, then both HTTP1/HTTP2 connections are \
      supported (via ALPN), but there is no multiplexing.
      """,
      default: [:http1]
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
    ],
    start_pool_metrics?: [
      type: :boolean,
      doc: "When true, pool metrics will be collected and available through `get_pool_status/2`",
      default: false
    ]
  ]

  @typedoc """
  The `:name` provided to Finch in `start_link/1`.
  """
  @type name() :: atom()

  @type scheme() :: :http | :https

  @type scheme_host_port() :: {scheme(), host :: String.t(), port :: :inet.port_number()}

  @type pool_identifier() :: url :: String.t() | scheme_host_port() | Finch.Pool.t()

  @typedoc """
  Pool metrics returned by `get_pool_status/2` for a single pool.
  """
  @type pool_metrics() ::
          [Finch.HTTP1.PoolMetrics.t()]
          | [Finch.HTTP2.PoolMetrics.t()]

  @typedoc """
  Pool metrics grouped by pool identifier when querying the `:default` configuration.
  """
  @type default_pool_metrics() :: %{required(Finch.Pool.t()) => pool_metrics()}

  @type request_opt() ::
          {:pool_timeout, timeout()}
          | {:receive_timeout, timeout()}
          | {:request_timeout, timeout()}

  @typedoc """
  Options used by request functions.
  """
  @type request_opts() :: [request_opt()]

  @typedoc """
  The reference used to identify a request sent using `async_request/3`.

  Use the `is_request_ref/1` guard when matching on async response messages in
  `c:GenServer.handle_info/2` or similar callbacks to ensure your code keeps
  working if the internal structure of the reference changes.
  """
  @opaque request_ref() :: Finch.Pool.Manager.request_ref()

  @doc """
  A guard that returns true if `ref` is a valid request reference from `async_request/3`.

  Use this guard when matching on async response messages in `c:GenServer.handle_info/2`
  so your code remains valid if the internal structure of the reference changes.

  ## Example

      require Finch

      def handle_info({ref, response}, state) when Finch.is_request_ref(ref) do
        # handle async response from Finch.async_request/3
      end

  """
  defguard is_request_ref(ref) when Finch.Pool.Manager.is_request_ref(ref)

  @typedoc """
  The stream function given to `stream/5`.
  """
  @type stream(acc) ::
          ({:status, integer}
           | {:headers, Mint.Types.headers()}
           | {:data, binary}
           | {:trailers, Mint.Types.headers()},
           acc ->
             acc)

  @typedoc """
  The stream function given to `stream_while/5`.
  """
  @type stream_while(acc) ::
          ({:status, integer}
           | {:headers, Mint.Types.headers()}
           | {:data, binary}
           | {:trailers, Mint.Types.headers()},
           acc ->
             {:cont, acc} | {:halt, acc})

  @doc """
  Start an instance of Finch.

  ## Options

    * `:name` - The name of your Finch instance. Required.
    * `:pools` - A map of pool identifiers to configuration options. See the ":pools" subsection below.

  ### :name

  The name of your Finch instance. It is used to identify the instance when making requests
  and when calling other functions like `Finch.start_pool/3` or `Finch.get_pool_status/2`.

  #### Examples

      Finch.start_link(name: MyFinch)

  ### :pools

  A map where each key identifies a pool and each value is a keyword list of pool configuration
  options (see "[Pool Configuration Options](#start_link/1-pool-configuration-options)" below).
  Default is `%{default: [size: #{@default_pool_size}, count: #{@default_pool_count}]}`.

  **Pool keys** may be:

  * URL string – A binary URL. Pools created from URLs use the `:default` tag unless you
    use a `t:Finch.Pool.t/0` struct as the key instead.
  * `t:Finch.Pool.t/0` struct – Created with `Finch.Pool.new/2`. Use this when you need
    tagged pools (e.g. to run multiple pools for the same host with different configs).
  * URL string with `http+unix://` or `https+unix://` – For Unix domain sockets (e.g.
    `"http+unix:///tmp/socket"`)
  * `:default` – Catch-all. Any request whose pool is not in the map will use this config
    when its pool is started.

  When making a request with a `:pool_tag` option, that tag must exist in your pool configuration.
  If it does not, the request uses the `:default` configuration.

  #### Examples

      # URL keys (pool uses :default tag)
      Finch.start_link(
        name: MyFinch,
        pools: %{
          "https://api.example.com" => [size: 10, count: 2]
        }
      )

      # Tagged pools via Finch.Pool.new/2
      Finch.start_link(
        name: MyFinch,
        pools: %{
          Finch.Pool.new("https://api.example.com", tag: :bulk) => [size: 100, count: 1],
          Finch.Pool.new("https://api.example.com", tag: :realtime) => [size: 10, count: 2]
        }
      )

      # Unix socket
      Finch.start_link(
        name: MyFinch,
        pools: %{
          "http+unix:///tmp/socket" => [size: 5]
        }
      )

      # Custom default configuration
      Finch.start_link(
        name: MyFinch,
        pools: %{
          :default => [size: 25, count: 2]
        }
      )

  ### Pool Configuration Options

  #{NimbleOptions.docs(@pool_config_schema)}
  """
  def start_link(opts) do
    name = finch_name!(opts)
    pools = Keyword.get(opts, :pools, []) |> pool_options!()
    {default_pool_config, pools} = Map.pop(pools, :default)

    config = %{
      registry_name: name,
      supervisor_name: concat_name(name, "PoolSupervisor"),
      supervisor_registry_name: Pool.Manager.supervisor_registry_name(name),
      default_pool_config: default_pool_config,
      pools: pools
    }

    Supervisor.start_link(__MODULE__, config, name: concat_name(name, "Supervisor"))
  end

  @doc """
  Finds a pool by its configuration and returns the pool pid.

  Returns `{:ok, pid}` if the pool exists, `:error` otherwise.

  This is useful for checking if a pool is available before making requests,
  or for advanced use cases where you need direct access to the pool process.

  ## Example

      case Finch.find_pool(MyFinch, Finch.Pool.new("https://api.internal", tag: :api)) do
        {:ok, pid} -> # Pool exists
        :error -> # Pool not found
      end
  """
  @spec find_pool(name(), Finch.Pool.t()) :: {:ok, pid()} | :error
  def find_pool(name, %Finch.Pool{} = pool) do
    case Pool.Manager.get_pool(name, pool, _start_pool? = false) do
      {pid, _mod} -> {:ok, pid}
      :not_found -> :error
    end
  end

  @doc """
  Starts a pool dynamically under Finch's internal supervision tree.

  Returns `:ok` if the pool was started or already exists.

  ## Options

  Same pool configuration options as `Finch.start_link/1`:
  `:size`, `:count`, `:protocols`, `:conn_opts`, etc.

  ## Example

      Finch.start_pool(MyFinch, Finch.Pool.new("https://api.example.com", tag: :api), size: 10)
  """
  @spec start_pool(name(), Finch.Pool.t(), keyword()) :: :ok
  def start_pool(name, pool, opts \\ [])

  def start_pool(name, %Finch.Pool{} = pool, opts) do
    {:ok, config} = Registry.meta(name, :config)
    pool_name = Finch.Pool.to_name(pool)

    # Avoid building the child_spec (cast_pool_opts, sanitize, etc.) if the pool already exists
    if Registry.lookup(config.supervisor_registry_name, pool_name) != [] do
      :ok
    else
      spec = Finch.Pool.child_spec([finch: name, pool: pool] ++ opts)

      case DynamicSupervisor.start_child(config.supervisor_name, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
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
      {Registry, keys: :duplicate, name: config.registry_name, meta: [config: config]},
      {Registry, keys: :unique, name: config.supervisor_registry_name},
      {DynamicSupervisor, name: config.supervisor_name, strategy: :one_for_one},
      {Pool.Manager, config}
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

      %Finch.Pool{} = pool ->
        {:ok, pool}

      {scheme, {:local, path}} when is_atom(scheme) and is_binary(path) ->
        ## TODO: Remove in Finch v1.0
        IO.warn("""
        Using {scheme, {:local, path}} as a pool key is deprecated. Use "#{scheme}+unix://#{path}" instead.

        For example:

            pools: %{
              "#{scheme}+unix://#{path}" => ...
            }
        """)

        {:ok, Finch.Pool.new({scheme, {:local, path}})}

      url when is_binary(url) ->
        {:ok, Finch.Pool.new(url)}

      _ ->
        {:error, %ArgumentError{message: "invalid destination: #{inspect(destination)}"}}
    end
  end

  @doc false
  def cast_pool_opts(opts) do
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

    # Only relevant to HTTP2, but just gracefully ignored in HTTP1.
    # Since we cannot handle server push responses, we need to disable the feature.
    client_settings =
      conn_opts
      |> Keyword.get(:client_settings, [])
      |> Keyword.put(:enable_push, false)

    ssl_key_log_file =
      Keyword.get(conn_opts, :ssl_key_log_file) || System.get_env("SSLKEYLOGFILE")

    ssl_key_log_file_device = ssl_key_log_file && File.open!(ssl_key_log_file, [:append])

    conn_opts =
      conn_opts
      |> Keyword.put(:ssl_key_log_file_device, ssl_key_log_file_device)
      |> Keyword.put(:transport_opts, transport_opts)
      |> Keyword.put(:protocols, valid[:protocols])
      |> Keyword.put(:client_settings, client_settings)

    mod =
      if :http1 in valid[:protocols] do
        Finch.HTTP1.Pool
      else
        Finch.HTTP2.Pool
      end

    %{
      mod: mod,
      size: valid[:size],
      count: valid[:count],
      conn_opts: conn_opts,
      conn_max_idle_time: to_native(valid[:conn_max_idle_time]),
      pool_max_idle_time: valid[:pool_max_idle_time],
      start_pool_metrics?: valid[:start_pool_metrics?]
    }
  end

  defp to_native(:infinity), do: :infinity
  defp to_native(time), do: System.convert_time_unit(time, :millisecond, :native)

  defp concat_name(name, suffix), do: :"#{name}.#{suffix}"

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

  ## Options

    * `:unix_socket` - Path to a Unix domain socket to connect to instead of the URL
      host/port. The URL scheme still determines whether HTTP or HTTPS is used.

    * `:pool_tag` - The tag to use when selecting which pool to use for this request.
      Defaults to `:default`.
  """
  @spec build(
          Request.method(),
          Request.url(),
          Request.headers(),
          Request.body(),
          Request.build_opts()
        ) ::
          Request.t()
  defdelegate build(method, url, headers \\ [], body \\ nil, opts \\ []), to: Request

  @doc """
  Streams an HTTP request and returns the accumulator.

  A function of arity 2 is expected as argument. The first argument
  is a tuple, as listed below, and the second argument is the
  accumulator. The function must return a potentially updated
  accumulator.

  See also `stream_while/5`.

  > ### HTTP2 streaming and back-pressure {: .warning}
  >
  > At the moment, streaming over HTTP2 connections do not provide
  > any back-pressure mechanism: this means the response will be
  > sent to the client as quickly as possible. Therefore, you must
  > not use streaming over HTTP2 for non-terminating responses or
  > when streaming large responses which you do not intend to keep
  > in memory.

  ## Stream commands

    * `{:status, status}` - the http response status
    * `{:headers, headers}` - the http response headers
    * `{:data, data}` - a streaming section of the http response body
    * `{:trailers, trailers}` - the http response trailers

  ## Options

  Shares options with `request/3`.

  ## Examples

      path = "/tmp/archive.zip"
      file = File.open!(path, [:write, :exclusive])
      url = "https://example.com/archive.zip"
      request = Finch.build(:get, url)

      Finch.stream(request, MyFinch, nil, fn
        {:status, status}, _acc ->
          IO.inspect(status)

        {:headers, headers}, _acc ->
          IO.inspect(headers)

        {:data, data}, _acc ->
          IO.binwrite(file, data)
      end)

      File.close(file)
  """
  @spec stream(Request.t(), name(), acc, stream(acc), request_opts()) ::
          {:ok, acc} | {:error, Exception.t(), acc}
        when acc: term()
  def stream(%Request{} = req, name, acc, fun, opts \\ []) when is_function(fun, 2) do
    fun = fn entry, acc ->
      {:cont, fun.(entry, acc)}
    end

    stream_while(req, name, acc, fun, opts)
  end

  @doc """
  Streams an HTTP request until it finishes or `fun` returns `{:halt, acc}`.

  A function of arity 2 is expected as argument. The first argument
  is a tuple, as listed below, and the second argument is the
  accumulator.

  The function must return:

    * `{:cont, acc}` to continue streaming
    * `{:halt, acc}` to halt streaming

  See also `stream/5`.

  > ### HTTP2 streaming and back-pressure {: .warning}
  >
  > At the moment, streaming over HTTP2 connections do not provide
  > any back-pressure mechanism: this means the response will be
  > sent to the client as quickly as possible. Therefore, you must
  > not use streaming over HTTP2 for non-terminating responses or
  > when streaming large responses which you do not intend to keep
  > in memory.

  ## Stream commands

    * `{:status, status}` - the http response status
    * `{:headers, headers}` - the http response headers
    * `{:data, data}` - a streaming section of the http response body
    * `{:trailers, trailers}` - the http response trailers

  ## Options

  Shares options with `request/3`.

  ## Examples

      path = "/tmp/archive.zip"
      file = File.open!(path, [:write, :exclusive])
      url = "https://example.com/archive.zip"
      request = Finch.build(:get, url)

      Finch.stream_while(request, MyFinch, nil, fn
        {:status, status}, acc ->
          IO.inspect(status)
          {:cont, acc}

        {:headers, headers}, acc ->
          IO.inspect(headers)
          {:cont, acc}

        {:data, data}, acc ->
          IO.binwrite(file, data)
          {:cont, acc}
      end)

      File.close(file)
  """
  @spec stream_while(Request.t(), name(), acc, stream_while(acc), request_opts()) ::
          {:ok, acc} | {:error, Exception.t(), acc}
        when acc: term()
  def stream_while(%Request{} = req, name, acc, fun, opts \\ []) when is_function(fun, 2) do
    request_span req, name do
      __stream__(req, name, acc, fun, opts)
    end
  end

  defp __stream__(%Request{} = req, name, acc, fun, opts) do
    {pool, pool_mod} = get_pool(req, name)
    pool_mod.request(pool, req, acc, fun, name, opts)
  end

  @doc """
  Sends an HTTP request and returns a `Finch.Response` struct.

  It can still raise exceptions if it was not possible to check out a connection in the given `:pool_timeout`.

  ## Options

    * `:pool_timeout` - This timeout is applied when we check out a connection from the pool.
      Default value is `5_000`.

    * `:receive_timeout` - The maximum time to wait for each chunk to be received before returning an error.
      Default value is `15_000`.

    * `:request_timeout` - The amount of time to wait for a complete response before returning an error.
      This timeout only applies to HTTP/1, and its current implementation is a best effort timeout,
      it does not guarantee the call will return precisely when the time has elapsed.
      Default value is `:infinity`.

  """
  @spec request(Request.t(), name(), request_opts()) ::
          {:ok, Response.t()}
          | {:error, Exception.t()}
  def request(req, name, opts \\ [])

  def request(%Request{} = req, name, opts) do
    request_span req, name do
      acc = {nil, [], [], []}

      fun = fn
        {:status, value}, {_, headers, body, trailers} ->
          {:cont, {value, headers, body, trailers}}

        {:headers, value}, {status, headers, body, trailers} ->
          {:cont, {status, headers ++ value, body, trailers}}

        {:data, value}, {status, headers, body, trailers} ->
          {:cont, {status, headers, [body | value], trailers}}

        {:trailers, value}, {status, headers, body, trailers} ->
          {:cont, {status, headers, body, trailers ++ value}}
      end

      case __stream__(req, name, acc, fun, opts) do
        {:ok, {status, headers, body, trailers}} ->
          {:ok,
           %Response{
             status: status,
             headers: headers,
             body: IO.iodata_to_binary(body),
             trailers: trailers
           }}

        {:error, error, _acc} ->
          {:error, error}
      end
    end
  end

  @doc """
  Sends an HTTP request and returns a `Finch.Response` struct
  or raises an exception in case of failure.

  See `request/3` for more detailed information.
  """
  @spec request!(Request.t(), name(), request_opts()) ::
          Response.t()
  def request!(%Request{} = req, name, opts \\ []) do
    case request(req, name, opts) do
      {:ok, resp} -> resp
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Sends an HTTP request asynchronously, returning a request reference.

  If the request is sent using HTTP1, an extra process is spawned to
  consume messages from the underlying socket. The messages are sent
  to the current process as soon as they arrive, as a firehose.  If
  you wish to maximize request rate or have more control over how
  messages are streamed, a strategy using `request/3` or `stream/5`
  should be used instead.

  ## Receiving the response

  Response information is sent to the calling process as it is received
  in `{ref, response}` tuples.

  If the calling process exits before the request has completed, the
  request will be canceled.

  Responses include:

    * `{:status, status}` - HTTP response status
    * `{:headers, headers}` - HTTP response headers
    * `{:data, data}` - section of the HTTP response body
    * `{:error, exception}` - an error occurred during the request
    * `:done` - request has completed successfully

  On a successful request, a single `:status` message will be followed
  by a single `:headers` message, after which more than one `:data`
  messages may be sent. If trailing headers are present, a final
  `:headers` message may be sent. Any `:done` or `:error` message
  indicates that the request has succeeded or failed and no further
  messages are expected.

  ## Example

      iex> req = Finch.build(:get, "https://httpbin.org/stream/5")
      iex> ref = Finch.async_request(req, MyFinch)
      iex> flush()
      {ref, {:status, 200}}
      {ref, {:headers, [...]}}
      {ref, {:data, "..."}}
      {ref, :done}

  ## Options

  Shares options with `request/3`.
  """
  @spec async_request(Request.t(), name(), request_opts()) :: request_ref()
  def async_request(%Request{} = req, name, opts \\ []) do
    {pool, pool_mod} = get_pool(req, name)
    pool_mod.async_request(pool, req, name, opts)
  end

  @doc """
  Cancels a request sent with `async_request/3`.
  """
  @spec cancel_async_request(request_ref()) :: :ok
  def cancel_async_request(request_ref) when Finch.Pool.Manager.is_request_ref(request_ref) do
    {pool_mod, _cancel_ref} = request_ref
    pool_mod.cancel_async_request(request_ref)
  end

  defp get_pool(%Request{scheme: scheme, unix_socket: unix_socket, pool_tag: tag}, name)
       when is_binary(unix_socket) do
    pool = Finch.Pool.from_name({scheme, {:local, unix_socket}, 0, tag})
    Pool.Manager.get_pool(name, pool)
  end

  defp get_pool(%Request{scheme: scheme, host: host, port: port, pool_tag: tag}, name) do
    pool = Finch.Pool.from_name({scheme, host, port, tag})
    Pool.Manager.get_pool(name, pool)
  end

  @doc """
  Get pool metrics.

  When given a URL or pool identifier tuple, this returns the metrics list for that specific
  pool. The number of items in the metrics list depends on the configured
  `:count` option and each entry will have a `pool_index` going from 1 to
  `:count`.

  When `:default` is provided, Finch returns the metrics for all pools started
  from the `:default` configuration. In this case the return value is a map
  keyed by each pool's `{scheme, host, port}` tuple with the corresponding
  metrics list as the value.

  The metrics struct depends on the pool scheme defined in the `:protocols`
  option: `Finch.HTTP1.PoolMetrics` for `:http1` and `Finch.HTTP2.PoolMetrics`
  for `:http2`. See the documentation for those modules for more details.

  `{:error, :not_found}` is returned in the following scenarios:

    * There is no pool registered for the given Finch instance and pool identifier.
    * The pool has `start_pool_metrics?: false` (the default).
    * `:default` is provided but no pools have been started from the
      `:default` configuration (or none have metrics enabled).

  ## Examples

      iex> Finch.get_pool_status(MyFinch, "https://httpbin.org")
      {:ok, [
        %Finch.HTTP1.PoolMetrics{
          pool_index: 1,
          pool_size: 50,
          available_connections: 43,
          in_use_connections: 7
        },
        %Finch.HTTP1.PoolMetrics{
          pool_index: 2,
          pool_size: 50,
          available_connections: 37,
          in_use_connections: 13
        }]
      }

      iex> Finch.get_pool_status(MyFinch, :default)
      {:ok,
       %{
         %Finch.Pool{host: "httpbin.com", port: 443, scheme: :https, tag: :default} => [
           %Finch.HTTP1.PoolMetrics{
             pool_index: 1,
             pool_size: 50,
             available_connections: 43,
             in_use_connections: 7
           }
         ]
       }}
  """
  @spec get_pool_status(name(), pool_identifier()) ::
          {:ok, pool_metrics()}
          | {:ok, default_pool_metrics()}
          | {:error, :not_found}

  def get_pool_status(finch_name, :default) do
    finch_name
    |> Pool.Manager.get_default_pools()
    |> Enum.reduce(%{}, fn {_pid, {pool_name, pool_mod, pool_count}}, acc ->
      case pool_mod.get_pool_status(finch_name, pool_name, pool_count) do
        {:ok, metrics} ->
          pool_id = Pool.from_name(pool_name)
          Map.put(acc, pool_id, metrics)

        {:error, :not_found} ->
          acc
      end
    end)
    |> case do
      result when result == %{} -> {:error, :not_found}
      result -> {:ok, result}
    end
  end

  def get_pool_status(finch_name, %Finch.Pool{} = pool) do
    case Pool.Manager.get_pool_supervisor(finch_name, pool) do
      {_pid, pool_name, pool_mod, pool_count} ->
        pool_mod.get_pool_status(finch_name, pool_name, pool_count)

      :not_found ->
        {:error, :not_found}
    end
  end

  def get_pool_status(finch_name, {scheme, host, port}) do
    pool = Finch.Pool.from_name({scheme, host, port, :default})
    get_pool_status(finch_name, pool)
  end

  def get_pool_status(finch_name, url_or_scheme) do
    pool = Finch.Pool.new(url_or_scheme)
    get_pool_status(finch_name, pool)
  end

  @doc """
  Stops the pool of processes associated with the given pool identifier.

  This function can be invoked to manually stop the pool for the given identifier
  when you know it's not going to be used anymore.

  Note that this function is not safe with respect to concurrent requests. Invoking it while
  another request to the same pool is taking place might result in the failure of that request.
  It is the responsibility of the client to ensure that no request to the same pool is taking
  place while this function is being invoked.
  """
  @spec stop_pool(name(), pool_identifier()) :: :ok | {:error, :not_found}
  def stop_pool(finch_name, %Finch.Pool{} = pool) do
    case Pool.Manager.get_pool_supervisor(finch_name, pool) do
      :not_found -> {:error, :not_found}
      {pid, _pool_name, _pool_mod, _pool_count} -> Supervisor.stop(pid)
    end
  end

  def stop_pool(finch_name, {scheme, host, port}) do
    pool = Finch.Pool.from_name({scheme, host, port, :default})
    stop_pool(finch_name, pool)
  end

  def stop_pool(finch_name, url_or_scheme) do
    pool = Finch.Pool.new(url_or_scheme)
    stop_pool(finch_name, pool)
  end
end
