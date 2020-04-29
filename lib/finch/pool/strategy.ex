defmodule Finch.Pool.Strategy do
  @moduledoc """
  Strategies for choosing which pool to route a request to.
  """

  @callback registry_value(pool_config :: term) :: term
  @callback handle_enqueue(pool_state :: term) :: :ok
  @callback choose_pool(registry_value :: term, pools :: [{pid, term}]) :: pid
end
