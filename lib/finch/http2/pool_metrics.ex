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

  def init(finch_name, shp, pool_idx) do
    ref = :atomics.new(length(@atomic_idx), [])
    :persistent_term.put({__MODULE__, finch_name, shp, pool_idx}, ref)

    :atomics.put(ref, @atomic_idx[:pool_idx], pool_idx)

    {:ok, ref}
  end

  def maybe_add({_finch_name, _shp, _pool_idx, %{start_pool_metrics?: false}}, _metrics_list),
    do: :ok

  def maybe_add({finch_name, shp, pool_idx, %{start_pool_metrics?: true}}, metrics_list) do
    ref = :persistent_term.get({__MODULE__, finch_name, shp, pool_idx})

    Enum.each(metrics_list, fn {metric_name, val} ->
      :atomics.add(ref, @atomic_idx[metric_name], val)
    end)
  end

  def get_pool_status(finch_name, shp) do
    case :persistent_term.get({__MODULE__, finch_name, shp}, nil) do
      nil -> {:error, :not_found}
      ref -> get_pool_status(ref)
    end
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
