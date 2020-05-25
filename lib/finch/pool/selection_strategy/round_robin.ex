defmodule Finch.Pool.SelectionStrategy.RoundRobin do
  @moduledoc """
  Cycle through the pools one by one, in a consistent order.
  """
  @behaviour Finch.Pool.SelectionStrategy

  @impl true
  def registry_value(%{count: count}) do
    atomics = :atomics.new(1, signed: false)
    %{strategy: __MODULE__, count: count, atomics: atomics}
  end

  @impl true
  def choose_pool([{_, {_, registry_value}} | _] = pools) do
    %{atomics: atomics, count: count} = registry_value
    index = :atomics.add_get(atomics, 1, 1)
    Enum.at(pools, rem(index, count))
  end
end
