defmodule Finch.Pool.Strategy.RoundRobin do
  @moduledoc """
  Selects pool workers in round-robin order using an atomics counter.

  This ensures an evenly distribution of tasks.

  It is recommended to share the same counter state across all usages of the same pool for proper
  round-robin. Client processes can be passed a reference to such counter or it can be stored in a
  `:persistent_term`.

  ## Example

      counter = Finch.Pool.Strategy.RoundRobin.new()
      Finch.request(req, MyFinch, pool_strategy: {Finch.Pool.Strategy.RoundRobin, counter})
  """

  @behaviour Finch.Pool.Strategy

  @impl Finch.Pool.Strategy
  @spec new() :: :atomics.atomics_ref()
  @spec new(term()) :: :atomics.atomics_ref()
  def new(_ \\ nil), do: :atomics.new(1, [])

  @impl Finch.Pool.Strategy
  def select(entries, counter) do
    idx = :atomics.add_get(counter, 1, 1)
    next = rem(idx - 1, length(entries))
    Enum.at(entries, next)
  end
end
