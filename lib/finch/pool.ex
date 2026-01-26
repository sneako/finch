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
      pool = Finch.Pool.new({:http, {:local, "/tmp/socket"}})

      # Create a tagged pool for a Unix socket
      pool = Finch.Pool.new({:http, {:local, "/tmp/socket"}}, tag: :api)
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

  @type pool_tag() :: term()

  @doc """
  Creates a new pool struct.

  The first argument can be:
  - A URL string (binary)
  - A `{scheme, {:local, path}}` tuple for Unix sockets

  The second argument is an optional keyword list with:
  - `:tag` - The tag for the pool (defaults to `:default`)

  ## Examples

      # From URL
      pool = Finch.Pool.new("https://api.example.com")

      # Tagged pool from URL
      pool = Finch.Pool.new("https://api.example.com", tag: :api)

      # Unix socket pool
      pool = Finch.Pool.new({:http, {:local, "/tmp/socket"}})

      # Tagged Unix socket pool
      pool = Finch.Pool.new({:http, {:local, "/tmp/socket"}}, tag: :api)
  """
  def new(input), do: new(input, [])

  def new(url, opts) when is_binary(url) do
    {scheme, host, port, _path, _query} = Finch.Request.parse_url(url)
    tag = Keyword.get(opts, :tag, :default)
    %__MODULE__{scheme: scheme, host: host, port: port, tag: tag}
  end

  def new({scheme, {:local, path}}, opts) when is_atom(scheme) and is_binary(path) do
    tag = Keyword.get(opts, :tag, :default)
    %__MODULE__{scheme: scheme, host: {:local, path}, port: 0, tag: tag}
  end

  def new(invalid, _) do
    raise ArgumentError,
          "expected Finch.Pool.new/2 to receive a URL string or {scheme, {:local, path}} tuple as first argument, got: #{inspect(invalid)}"
  end

  @doc false
  # Converts a pool name tuple {scheme, host, port, tag} back to a Pool struct.
  # This is the inverse of to_name/1.
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
end
