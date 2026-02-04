defmodule Finch.Pool do
  @moduledoc """
  Defines a pool structure for identifying and configuring connection pools.

  A pool is identified by its `scheme`, `host`, `port` and `tag`.
  You can create pool structs using `new/2`.

  ## Examples

      # Create a pool from a URL
      pool = Finch.Pool.new("https://api.example.com")

      # Create a tagged pool from a URL
      pool = Finch.Pool.new("https://api.example.com", tag: :api)

      # Create a pool for a Unix socket
      pool = Finch.Pool.new("http+unix:///tmp/socket")

      # Create a tagged pool for a Unix socket
      pool = Finch.Pool.new("http+unix:///tmp/socket", tag: :api)

  ## User-managed pools

  Use `child_spec/1` to start pools under your own supervision tree. The Finch
  instance must be started before the pool. See `child_spec/1` for options and examples.
  """

  @enforce_keys [:scheme, :host, :port]
  defstruct [:scheme, :host, :port, tag: :default]

  @type scheme :: :http | :https
  @type host :: String.t() | {:local, String.t()}

  @type t :: %__MODULE__{
          scheme: scheme(),
          host: host(),
          port: :inet.port_number(),
          tag: pool_tag()
        }

  @typedoc """
  The tag used to identify a pool.

  While any `term()` is supported, the tag becomes part of the registry key used
  for pool lookups. Simple terms like atoms or strings are recommended for best
  performance.
  """
  @type pool_tag() :: term()

  @doc """
  Creates a new pool struct from a URL.

  Supports `http://`, `https://`, `http+unix://`, and `https+unix://` schemes.

  The second argument is an optional keyword list with:
  - `:tag` - The tag for the pool (defaults to `:default`)

  ## Examples

      # From URL
      pool = Finch.Pool.new("https://api.example.com")

      # Unix socket pool using URL
      pool = Finch.Pool.new("http+unix:///tmp/socket")

      # Tagged pool
      pool = Finch.Pool.new("http+unix:///tmp/socket", tag: :api)
  """
  def new(input, opts \\ [])

  def new(url, opts) when is_binary(url) do
    tag = Keyword.get(opts, :tag, :default)
    parse_new(url, tag)
  end

  def new({scheme, {:local, path}}, opts) when is_atom(scheme) and is_binary(path) do
    tag = Keyword.get(opts, :tag, :default)
    %__MODULE__{scheme: scheme, host: {:local, path}, port: 0, tag: tag}
  end

  def new(invalid, _) do
    raise ArgumentError,
          "expected Finch.Pool.new/2 to receive a URL string, got: #{inspect(invalid)}"
  end

  defp parse_new(url, tag) do
    parsed = URI.parse(url)

    case parsed.scheme do
      "https" ->
        %__MODULE__{scheme: :https, host: parsed.host, port: parsed.port, tag: tag}

      "http" ->
        %__MODULE__{scheme: :http, host: parsed.host, port: parsed.port, tag: tag}

      "https+unix" ->
        %__MODULE__{scheme: :https, host: {:local, parsed.path}, port: 0, tag: tag}

      "http+unix" ->
        %__MODULE__{scheme: :http, host: {:local, parsed.path}, port: 0, tag: tag}

      nil ->
        raise ArgumentError, "scheme is required for url: #{URI.to_string(parsed)}"

      scheme ->
        raise ArgumentError, "invalid scheme \"#{scheme}\" for url: #{URI.to_string(parsed)}"
    end
  end

  @doc false
  def from_name({scheme, host, port}) do
    %__MODULE__{scheme: scheme, host: host, port: port}
  end

  def from_name({scheme, host, port, tag}) do
    %__MODULE__{scheme: scheme, host: host, port: port, tag: tag}
  end

  @doc false
  # This must only be called from the PoolManager,
  # so all name management belongs to a single place.
  def to_name(%__MODULE__{scheme: s, host: h, port: p, tag: tag}), do: {s, h, p, tag}

  @doc """
  Returns a child specification for starting a pool under your own supervision tree.

  This allows you to manage the lifecycle of pools independently from Finch's
  internal DynamicSupervisor. The pools integrate fully with Finch's APIs.

  ## Options

    * `:finch` - Required. The name of your Finch instance.
    * `:pool` - Required. A `Finch.Pool.t()` struct identifying the pool.
    * All pool configuration options from `Finch.start_link/1` are supported:
      `:size`, `:count`, `:protocols`, `:conn_opts`, etc.

  ## Example

      children = [
        {Finch, name: MyFinch},
        {Finch.Pool, finch: MyFinch, pool: Finch.Pool.new("https://api.internal", tag: :api), size: 10}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

  ## Notes

    * The Finch instance must be started before the user-managed pool
    * `Finch.stop_pool/2` works on user-managed pools
    * `Finch.get_pool_status/2` works if `start_pool_metrics?: true`
  """
  def child_spec(opts) do
    finch_name = Keyword.fetch!(opts, :finch)
    pool = Keyword.fetch!(opts, :pool)

    unless is_struct(pool, __MODULE__) do
      raise ArgumentError, "expected :pool to be a Finch.Pool.t() struct, got: #{inspect(pool)}"
    end

    pool_opts = opts |> Keyword.delete(:finch) |> Keyword.delete(:pool)
    Finch.Pool.Manager.pool_child_spec(finch_name, pool, pool_opts)
  end
end
