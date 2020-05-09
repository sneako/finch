defmodule Finch.Pool.SelectionStrategy do
  @moduledoc """
  Strategies for choosing which pool to route a request to.
  """

  @type pool_config :: map()
  @type pool_mod :: module()
  @type registry_value :: map()
  @type pool_list :: [{pid(), {pool_mod(), registry_value()}}]

  @doc """
  Returns a map that will be stored alongside the pool pids in the Regsitry.
  Must include at least a `:strategy` key with a Strategy module as the value,
  but can also include more information to be used by the strategy implementation.
  """
  @callback registry_value(pool_config()) :: registry_value()

  @doc """
  Receives the list of pool pids that is stored in the Registry and must
  return a single pool pid.
  """
  @callback choose_pool(pool_list()) :: pid()
end
