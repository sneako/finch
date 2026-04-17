defmodule Finch.PoolMetrics do
  @moduledoc false

  # Unified pool metrics backed by a single ETS table per Finch instance.
  #
  # Each worker stores one row: {{pool_name, pool_idx}, metric1, metric2, ...}
  # The key is {pool_name, pool_idx}; metric values occupy positions 2, 3, ...
  # Protocol-specific modules (HTTP1/HTTP2 PoolMetrics) define which position
  # holds which metric.
  #
  # The ETS table is created with `read_concurrency: true, write_concurrency: :auto`
  # for scalable concurrent access from pool workers.

  @doc """
  Returns the ETS table name for a Finch instance.
  """
  @spec table_name(atom()) :: atom()
  def table_name(finch_name), do: :"#{finch_name}.PoolMetrics"

  @doc """
  Creates the ETS table for a Finch instance. Called once during Finch.init/1.
  """
  @spec new(atom()) :: :ets.table()
  def new(finch_name) do
    :ets.new(table_name(finch_name), [
      :ordered_set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])
  end

  @doc """
  Inserts a full metrics row for a pool worker.
  `row` is a tuple like `{{pool_name, pool_idx}, val1, val2, ...}`.
  """
  @spec insert(atom(), term(), pos_integer(), list()) :: true
  def insert(table, pool_name, pool_idx, row) when is_list(row) do
    entry = [{pool_name, pool_idx}] ++ row
    :ets.insert(table, List.to_tuple(entry))
  end

  @doc """
  Atomically increments the value at `position` by `delta`.
  Position 2 is the first metric value (position 1 is the key).
  """
  @spec update(atom(), term(), pos_integer(), pos_integer(), integer()) :: integer()
  def update(table, pool_name, pool_idx, position, delta) do
    :ets.update_counter(table, {pool_name, pool_idx}, {position, delta})
  end

  @doc """
  Sets the value at `position` to an absolute value.
  """
  @spec put(atom(), term(), pos_integer(), pos_integer(), integer()) :: true
  def put(table, pool_name, pool_idx, position, value) do
    :ets.update_element(table, {pool_name, pool_idx}, {position, value})
  end

  @doc """
  Returns all metrics rows for the given pool_name, using ordered_set prefix lookup.
  """
  @spec get_all_rows(Finch.name(), term()) :: [tuple()]
  def get_all_rows(table, pool_name) do
    table
    |> table_name()
    |> :ets.match_object({{pool_name, :_}, :_, :_, :_})
  end

  @doc """
  Deletes the metrics row for a given pool worker.
  Accepts the ETS table name directly.
  """
  @spec delete(atom(), term(), pos_integer()) :: true
  def delete(table, pool_name, pool_idx) do
    :ets.delete(table, {pool_name, pool_idx})
  end

  @doc """
  Deletes all metrics rows for all workers of a given pool.
  """
  @spec delete_pool(atom(), term()) :: true
  def delete_pool(finch_name, pool_name) do
    table = table_name(finch_name)
    :ets.match_delete(table, {{pool_name, :_}, :_, :_, :_})
  end
end
