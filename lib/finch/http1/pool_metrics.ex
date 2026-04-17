defmodule Finch.HTTP1.PoolMetrics do
  @moduledoc """
  HTTP1 Pool metrics.

  Available metrics:

    * `:pid` - The pid of the pool worker process
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
    :pid,
    :pool_index,
    :pool_size,
    :available_connections,
    :in_use_connections
  ]

  alias Finch.PoolMetrics

  # Row layout: {{pool_name, pool_idx}, pool_size, in_use_connections, pid}
  @pos_in_use 3

  def init(finch_name, pool_name, pool_idx, pool_size) do
    table = PoolMetrics.table_name(finch_name)
    PoolMetrics.insert(table, pool_name, pool_idx, [pool_size, 0, self()])
    {:ok, {table, pool_name, pool_idx}}
  end

  def maybe_add(nil, _, _), do: :ok

  def maybe_add({table, pool_name, pool_idx}, :in_use_connections, delta) do
    PoolMetrics.update(table, pool_name, pool_idx, @pos_in_use, delta)
  end

  def get_pool_status(finch_name, pool_name, pool_idx) do
    table = PoolMetrics.table_name(finch_name)

    case PoolMetrics.get_row(table, pool_name, pool_idx) do
      nil ->
        {:error, :not_found}

      {_key, pool_size, in_use, pid} ->
        {:ok,
         %__MODULE__{
           pid: pid,
           pool_index: pool_idx,
           pool_size: pool_size,
           available_connections: pool_size - in_use,
           in_use_connections: in_use
         }}
    end
  end
end
