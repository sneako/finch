defmodule Finch.Pool do
  # Defines a behaviour that both http1 and http2 pools need to implement.
  @moduledoc false

  @typedoc false
  @type request_ref :: {pool_mod :: module(), cancel_ref :: term()}

  @doc false
  @callback request(
              pid(),
              Finch.Request.t(),
              acc,
              Finch.stream(acc),
              Finch.name(),
              list()
            ) :: {:ok, acc} | {:error, term(), acc}
            when acc: term()

  @doc false
  @callback async_request(
              pid(),
              Finch.Request.t(),
              Finch.name(),
              list()
            ) :: request_ref()

  @doc false
  @callback cancel_async_request(request_ref()) :: :ok

  @doc false
  @callback get_pool_status(finch_name :: atom(), %__MODULE__{}) ::
              {:ok, list(map)} | {:error, :not_found}

  @enforce_keys [:scheme, :host, :port]
  defstruct [:scheme, :host, :port]

  @type t :: %__MODULE__{
          scheme: :http | :https,
          host: String.t() | {:local, String.t()},
          port: :inet.port_number()
        }

  @doc false
  def new(scheme, host, port) do
    %__MODULE__{
      scheme: scheme,
      host: host,
      port: port
    }
  end

  @doc false
  def from_url(url) when is_binary(url) do
    {scheme, host, port, _path, _query} = Finch.Request.parse_url(url)
    new(scheme, host, port)
  end

  @doc false
  def to_shp(%__MODULE__{scheme: s, host: h, port: p}), do: {s, h, p}

  @doc false
  defguard is_request_ref(ref) when tuple_size(ref) == 2 and is_atom(elem(ref, 0))
end
