defmodule Finch.HTTP2.PoolMetrics do
  @moduledoc """
  HTTP2 Pool metrics.

  Available metrics:

    * `:pool_index` - Index of the pool
    * `:in_flight_requests` - Number of requests currently on the connection

  Caveats:

    * HTTP2 pools have only one connection and leverage the multiplex nature
    of the protocol. That's why we only keep the in flight requests, representing
    the number of streams currently running on the connection.
  """
  @type t :: %__MODULE__{}

  defstruct [
    :pool_index,
    :in_flight_requests
  ]

  @atomic_idx [
    pool_idx: 1,
    in_flight_requests: 2
  ]

  def init(finch_name, shp, pool_idx) do
    ref = :atomics.new(length(@atomic_idx), [])
    :atomics.put(ref, @atomic_idx[:pool_idx], pool_idx)

    :persistent_term.put({__MODULE__, finch_name, shp, pool_idx}, ref)
    {:ok, ref}
  end

  def maybe_add(nil, _metrics_list), do: :ok

  def maybe_add(ref, metrics_list) do
    Enum.each(metrics_list, fn {metric_name, val} ->
      :atomics.add(ref, @atomic_idx[metric_name], val)
    end)
  end

  def get_pool_status(name, shp, pool_idx) do
    {__MODULE__, name, shp, pool_idx}
    |> :persistent_term.get(nil)
    |> get_pool_status()
  end

  def get_pool_status(nil), do: {:error, :not_found}

  def get_pool_status(ref) do
    %{
      pool_idx: pool_idx,
      in_flight_requests: in_flight_requests
    } =
      @atomic_idx
      |> Enum.map(fn {k, idx} -> {k, :atomics.get(ref, idx)} end)
      |> Map.new()

    result = %__MODULE__{
      pool_index: pool_idx,
      in_flight_requests: in_flight_requests
    }

    {:ok, result}
  end
end
