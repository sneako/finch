defmodule Finch.Pool.RoundRobin do
  @moduledoc """
  Cycle through the pools one by one, in a consistent order.
  """
  @behaviour Finch.Pool.Strategy

  @impl true
  def registry_value(%{count: count}) do
    counter = :counters.new(1, [:atomics])
    %{strategy: __MODULE__, counter: counter, count: count}
  end

  @impl true
  def handle_enqueue(%{counter: counter}) do
    :counters.add(counter, 1, 1)
  end

  @impl true
  def choose_pool([{_, %{counter: counter, count: count}} | _] = pids) do
    index = :counters.get(counter, 1)
    {pid, _} = Enum.at(pids, rem(index, count))

    pid
  end
end
