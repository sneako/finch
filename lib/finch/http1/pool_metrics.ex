defmodule Finch.HTTP1.PoolMetrics do
  @moduledoc """
  HTTP1 Pool metrics. TODO: Add more description
  """
  defstruct [
    :pool_index,
    :pool_size,
    :available_connections,
    :in_use_connections
  ]

  @atomic_idx [
    pool_idx: 1,
    pool_size: 2,
    in_use_connections: 3
  ]

  def init(finch_name, shp, pool_idx, pool_size) do
    ref = :atomics.new(length(@atomic_idx), [])
    :persistent_term.put({__MODULE__, finch_name, shp, pool_idx}, ref)
    :atomics.add(ref, @atomic_idx[:pool_idx], pool_idx)
    :atomics.add(ref, @atomic_idx[:pool_size], pool_size)
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

  def get_pool_status(finch_name, shp, pool_idx) do
    case :persistent_term.get({__MODULE__, finch_name, shp, pool_idx}, nil) do
      nil ->
        {:error, :not_found}

      ref ->
        get_pool_status(ref)
    end
  end

  def get_pool_status(ref) when is_reference(ref) do
    %{
      pool_idx: pool_idx,
      pool_size: pool_size,
      in_use_connections: in_use_connections
    } =
      @atomic_idx
      |> Enum.map(fn {k, idx} -> {k, :atomics.get(ref, idx)} end)
      |> Map.new()

    result = %__MODULE__{
      pool_index: pool_idx,
      pool_size: pool_size,
      available_connections: pool_size - in_use_connections,
      in_use_connections: in_use_connections
    }

    {:ok, result}
  end
end
