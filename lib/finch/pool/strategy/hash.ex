defmodule Finch.Pool.Strategy.Hash do
  @moduledoc """
  Selects a pool worker by hashing a key, so the same key always maps to the same worker.

  Useful for connection affinity: e.g. team IDs, session tokens, or any scenario where
  routing the same logical entity to the same connection is beneficial.

  This strategy takes a `key` and selects a worker using `:erlang.phash2/2`.
  This ensures that tasks classified under the same key will be delivered to the same worker,
  which is useful to classify events by key and work on them sequentially on the worker,
  distributing different keys across different workers.

  If no key is given, it uses `self()` when constructing a state.

  ## Example

      key = Finch.Pool.Strategy.Hash.new()
      Finch.request(req, MyFinch, pool_strategy: {Finch.Pool.Strategy.Hash, key})
      ## equivalent to the above
      Finch.request(req, MyFinch, pool_strategy: {Finch.Pool.Strategy.Hash, self()})

      key = Finch.Pool.Strategy.Hash.new(tenant_id)
      Finch.request(req, MyFinch, pool_strategy: {Finch.Pool.Strategy.Hash, key})
      ## equivalent to the above
      Finch.request(req, MyFinch, pool_strategy: {Finch.Pool.Strategy.Hash, tenant_id})
  """

  @behaviour Finch.Pool.Strategy

  @impl Finch.Pool.Strategy
  @spec new() :: term()
  @spec new(key :: term()) :: term()
  def new(key \\ self()), do: key

  @impl Finch.Pool.Strategy
  def select(entries, key) do
    idx = :erlang.phash2(key, length(entries))
    Enum.at(entries, idx)
  end
end
