defmodule Finch.Pool.Random do
  @moduledoc """
  Randomly chooses a pool. Minimal overhead, but not necessarily optimal.
  """

  @behaviour Finch.Pool.Strategy

  @impl true
  def registry_value(_), do: %{strategy: __MODULE__}

  @impl true
  def handle_enqueue(_), do: :ok

  @impl true
  def choose_pool(pids) do
    {pid, _} = Enum.random(pids)
    pid
  end
end
