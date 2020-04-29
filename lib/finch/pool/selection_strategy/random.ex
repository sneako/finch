defmodule Finch.Pool.SelectionStrategy.Random do
  @moduledoc """
  Randomly chooses a pool. Minimal overhead, but not necessarily optimal.
  """

  @behaviour Finch.Pool.SelectionStrategy

  @impl true
  def registry_value(_), do: %{strategy: __MODULE__}

  @impl true
  def choose_pool(pids) do
    Enum.random(pids)
  end
end
