defmodule Finch.HTTP2.PoolMetrics do
  @moduledoc """
  HTTP2 Pool metrics. TODO: Add more description
  """
  defstruct [
    :pool_index,
    :in_flight_requests
  ]

  @atomic_idx [
    pool_idx: 1,
    in_flight_requests: 2
  ]

  def init(pool_idx) do
    ref = :atomics.new(length(@atomic_idx), [])
    :atomics.put(ref, @atomic_idx[:pool_idx], pool_idx)

    {:ok, ref}
  end

  def maybe_add(nil, _metrics_list), do: :ok

  def maybe_add(ref, metrics_list) when is_reference(ref) do
    Enum.each(metrics_list, fn {metric_name, val} ->
      :atomics.add(ref, @atomic_idx[metric_name], val)
    end)
  end

  def get_pool_status(ref) when is_reference(ref) do
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
