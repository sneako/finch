defmodule Finch.Pool.Strategy do
  @moduledoc """
  Strategies for choosing which pool to route a request to.
  """

  @type registry_value :: map()
  @type pool_list :: [{pool :: pid(), registry_value()}]

  @doc """
  Returns a map that will be stored alongside the pool pids in the Regsitry.
  Must include at least a `:strategy` key with a Strategy module as the value,
  but can also include more information to be used by the strategy implementation.
  """
  @callback registry_value(pool_config :: map()) :: registry_value()

  @doc """
  Receives the value returned from `registry_value/1`, and executed whenever the
  pool receives a request to checkout a connection.
  """
  @callback handle_enqueue(registry_value()) :: :ok

  @doc """
  Receives the list of pool pids that is stored in the Registry and must
  return a single pool pid.
  """
  @callback choose_pool(pool_list()) :: pool :: pid()
end
