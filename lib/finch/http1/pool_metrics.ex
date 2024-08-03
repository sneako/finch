defmodule Finch.HTTP1.PoolMetrics do
  @moduledoc """
  HTTP1 Pool metrics.

  Available metrics:

    * `:pool_index` - Index of the pool
    * `:pool_size` - Total number of connections of the pool
    * `:available_connections` - Number of available connections
    * `:in_use_connections` - Number of connections currently in use

  Caveats:

    * A given number X of `available_connections` does not mean that currently
    exists X connections to the server sitting on the pool. Because Finch uses 
    a lazy strategy for workers initialization, every pool starts with it's 
    size as available connections even if they are not started yet. In practice
    this means that `available_connections` may be connections sitting on the pool
    or available space on the pool for a new one if required.

  """
  @type t :: %__MODULE__{}

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

  def init(registry, shp, pool_idx, pool_size) do
    ref = :atomics.new(length(@atomic_idx), [])
    :atomics.add(ref, @atomic_idx[:pool_idx], pool_idx)
    :atomics.add(ref, @atomic_idx[:pool_size], pool_size)

    :persistent_term.put({__MODULE__, registry, shp, pool_idx}, ref)
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
