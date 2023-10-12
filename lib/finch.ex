defmodule Finch do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Finch.{PoolManager, Request, Response}
  require Finch.Pool

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

  @type request_opt() :: {:pool_timeout, pos_integer()} | {:receive_timeout, pos_integer()}

  @typedoc """
  Options used by request functions.
  """
  @type request_opts() :: [request_opt()]

  @typedoc """
  The reference used to identify a request sent using `async_request/3`.
  """
  @opaque request_ref() :: Finch.Pool.request_ref()

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

  See also `stream_while/5`.

  ## Stream commands

    * `{:status, status}` - the http response status
    * `{:headers, headers}` - the http response headers
    * `{:data, data}` - a streaming section of the http response body
    * `{:trailers, trailers}` - the http response trailers

  ## Options

  Shares options with `request/3`.

  ## Examples
      1)
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

      2) An example where you download an URL in streams into a temp file.
       It supports redirections.

      {:ok, path} = Plug.upload.random_file("temp-stream")
      {:ok, file} = File.open(path, [:binary, :write])

      # below is a redirected URL:
      url = "https://source.unsplash.com/QT-l619id6w"

      defp handle_headers(headers, 302), do:
        Enum.find(headers, &(elem(&1, 0) == "location"))

      defp handle_headers(headers, 200), do: headers

      defp handle_headers(_, _), do: {:halt, "bad redirection"}

      defp handle_data(_, {"location", location}, file), do:
        Finch.build(:get, location) |> stream_write(file)

      defp handle_data(_, {:halt, "bad redirection"}, _), do:
        {:error, "bad redirection"}

      defp handle_data(data, _, file) do
        case IO.binwrite(file, data) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      request = Finch.build(:get, url)
      Finch.stream(request, MyFinch, nil, fn
        {:status, status}, _acc ->
          status

        {:headers, headers}, status ->
          handle_headers(headers, status)

        {:data, data}, headers ->
          handle_data(data, headers, file)
      end)

      File.close!(file)

  """
  @spec stream(Request.t(), name(), acc, stream(acc), request_opts()) ::
          {:ok, acc} | {:error, Exception.t()}
        when acc: term()
  def stream(%Request{} = req, name, acc, fun, opts \\ []) when is_function(fun, 2) do
    fun =
      fn entry, acc ->
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
          {:ok, acc} | {:error, Exception.t()}
        when acc: term()
  def stream_while(%Request{} = req, name, acc, fun, opts \\ []) when is_function(fun, 2) do
    request_span req, name do
      __stream__(req, name, acc, fun, opts)
    end
  end

  defp __stream__(%Request{} = req, name, acc, fun, opts) do
    {pool, pool_mod} = get_pool(req, name)
    pool_mod.request(pool, req, acc, fun, opts)
  end

  @doc """
  Sends an HTTP request and returns a `Finch.Response` struct.

  ## Options

    * `:pool_timeout` - This timeout is applied when we check out a connection from the pool.
      Default value is `5_000`.

    * `:receive_timeout` - The maximum time to wait for a response before returning an error.
      Default value is `15_000`.

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
          {:cont, {status, headers, [value | body], trailers}}

        {:trailers, value}, {status, headers, body, trailers} ->
          {:cont, {status, headers, body, trailers ++ value}}
      end

      with {:ok, {status, headers, body, trailers}} <- __stream__(req, name, acc, fun, opts) do
        {:ok,
         %Response{
           status: status,
           headers: headers,
           body: body |> Enum.reverse() |> IO.iodata_to_binary(),
           trailers: trailers
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
    pool_mod.async_request(pool, req, opts)
  end

  @doc """
  Cancels a request sent with `async_request/3`.
  """
  @spec cancel_async_request(request_ref()) :: :ok
  def cancel_async_request(request_ref) when Finch.Pool.is_request_ref(request_ref) do
    {pool_mod, _cancel_ref} = request_ref
    pool_mod.cancel_async_request(request_ref)
  end

  defp get_pool(%Request{scheme: scheme, unix_socket: unix_socket}, name)
       when is_binary(unix_socket) do
    PoolManager.get_pool(name, {scheme, {:local, unix_socket}, 0})
  end

  defp get_pool(%Request{scheme: scheme, host: host, port: port}, name) do
    PoolManager.get_pool(name, {scheme, host, port})
  end
end
