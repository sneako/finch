defmodule Finch.Pool.Strategy do
  @moduledoc """
  Behaviour for selecting a pool worker when multiple workers are registered under the same pool key.

  When Finch is configured with `count: N`, N pool workers register under the same key in a
  `:duplicate` Registry. The strategy selects one worker per request. The strategy callback and
  its state are passed in request `opts` (e.g. `pool_strategy: {MyStrategy, state}`); the caller
  owns and manages strategy state.

  ## Using a built-in strategy

      # Round-robin (state is an atomics counter)
      counter = Finch.Pool.Strategy.RoundRobin.new()
      Finch.request(req, MyFinch, pool_strategy: {Finch.Pool.Strategy.RoundRobin, counter})

  For performance-critical paths, pass the strategy function directly to avoid dynamic module dispatch:

      Finch.request(req, MyFinch, pool_strategy: {&Finch.Pool.Strategy.RoundRobin.select/2, counter})

      # Hash-based (same key always maps to same worker; useful for connection affinity)
      Finch.request(req, MyFinch, pool_strategy: {Finch.Pool.Strategy.HashBased, team_id})

  ## Custom strategy

  Implement this behaviour and pass your module and state in request opts:

      defmodule MyApp.LeastBusy do
        @behaviour Finch.Pool.Strategy

        @impl true
        def select(entries, _) do
          Enum.min_by(entries, fn {pid, _mod} ->
            case Process.info(pid, :message_queue_len) do
              {:message_queue_len, len} -> len
              nil -> :infinity
            end
          end)
        end
      end

      Finch.request(req, MyFinch, pool_strategy: MyApp.LeastBusy)

  Strategies may implement the optional `new/0` or `new/1` callbacks to create state; the
  caller can also construct state themselves. Store state wherever makes sense (process state,
  `:persistent_term`, Application env, etc.).
  """

  @type pool_entry :: {pid(), module()}

  @doc """
  Optional. Returns initial state for strategies that need no argument (e.g. Random, RoundRobin).
  """
  @callback new() :: term()

  @doc """
  Optional. Returns initial state for strategies that take a key or option (e.g. HashBased).
  """
  @callback new(term()) :: term()
  @optional_callbacks new: 0, new: 1

  @doc """
  Selects one pool entry from the non-empty list of registered workers.

  Called by Finch when multiple workers exist for the pool. The same state is passed for each
  call; the caller is responsible for any mutable state (e.g. atomics).
  """
  @callback select(entries :: [pool_entry(), ...], state :: term()) :: pool_entry()
end
