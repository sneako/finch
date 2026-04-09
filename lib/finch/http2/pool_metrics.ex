defmodule Finch.HTTP2.PoolMetrics do
  @moduledoc """
  HTTP2 Pool metrics.

  Available metrics:

    * `:pool_index` - Index of the pool
    * `:in_flight_requests` - Number of requests currently on the connection
    * `:available_connections` - Number of available connections
    * `:max_concurrent_streams` - The server's max concurrent streams setting.
      This is 0 until the server's SETTINGS frame has been received.

  Caveats:

    * HTTP2 pools have only one connection and leverage the multiplex nature
    of the protocol. That's why we only keep the in flight requests, representing
    the number of streams currently running on the connection.
  """
  @type t :: %__MODULE__{}

  defstruct [
    :pool_index,
    :in_flight_requests,
    :available_connections,
    :max_concurrent_streams
  ]

  alias Finch.PoolMetrics

  # Row layout: {{pool_name, pool_idx}, in_flight_requests, max_concurrent_streams}
  @pos_in_flight 2
  @pos_max_streams 3

  @doc false
  def init(finch_name, pool_name, pool_idx) do
    table = PoolMetrics.table_name(finch_name)
    PoolMetrics.insert(table, pool_name, pool_idx, [0, 0])
    {:ok, {table, pool_name, pool_idx}}
  end

  @doc false
  def maybe_add(nil, _, _), do: :ok

  def maybe_add({table, pool_name, pool_idx}, :in_flight_requests, delta) do
    PoolMetrics.update(table, pool_name, pool_idx, @pos_in_flight, delta)
  end

  @doc false
  def maybe_put(nil, _metric, _value), do: :ok

  def maybe_put({table, pool_name, pool_idx}, :max_concurrent_streams, value) do
    PoolMetrics.put(table, pool_name, pool_idx, @pos_max_streams, value)
  end

  @doc false
  def get_pool_status(finch_name, pool_name, pool_idx) do
    table = PoolMetrics.table_name(finch_name)

    case PoolMetrics.get_row(table, pool_name, pool_idx) do
      nil ->
        {:error, :not_found}

      {_key, in_flight, max_streams} ->
        {:ok,
         %__MODULE__{
           pool_index: pool_idx,
           in_flight_requests: in_flight,
           available_connections: max_streams - in_flight,
           max_concurrent_streams: max_streams
         }}
    end
  end
end
