defmodule Finch.Pool.Strategy.Random do
  @moduledoc """
  Selects a pool worker uniformly at random. No state required.

  This is the default when no `pool_strategy` option is given, it is the fastest one to select
  a worker, which is ideal if your workers will perform many short tasks.
  """

  @behaviour Finch.Pool.Strategy

  @impl Finch.Pool.Strategy
  @spec new() :: nil
  @spec new(term()) :: nil
  def new(_ \\ nil), do: nil

  @impl Finch.Pool.Strategy
  def select(entries, _) do
    Enum.random(entries)
  end
end
