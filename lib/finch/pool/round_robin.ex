defmodule Finch.Pool.RoundRobin do
  @moduledoc """
  Cycle through the pools one by one, in a consistent order.
  """
  @behaviour Finch.Pool.Strategy

  @impl true
  def init_pool_group(shp, %{ets_name: ets}, _pool_config) do
    :ets.insert(ets, {shp, -1})
    :ok
  end

  @impl true
  def registry_value(shp, %{ets_name: ets}, %{count: count}) do
    %{strategy: __MODULE__, shp: shp, count: count, ets_name: ets}
  end

  @impl true
  def choose_pool([{_, registry_value} | _] = pids) do
    %{ets_name: name, shp: shp, count: count} = registry_value
    index = :ets.update_counter(name, shp, {2, 1, count, 1})
    {pid, _} = Enum.at(pids, rem(index, count))

    pid
  end
end
