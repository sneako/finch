defmodule Finch.Pool.Supervisor do
  @moduledoc false

  # Supervisor each process in a pool (effectively one child per pool_config.count)
  use Supervisor, restart: :transient

  def start_link({name, arg}) do
    Supervisor.start_link(__MODULE__, arg, name: name)
  end

  def init({registry_name, pool, pool_config, track_default?}) do
    pool_name = Finch.Pool.to_name(pool)

    if track_default? do
      Registry.register(registry_name, :default, {pool_name, pool_config.mod, pool_config.count})
    end

    specs =
      Enum.map(1..pool_config.count, fn pool_idx ->
        pool_args = {pool, pool_name, registry_name, pool_config, pool_idx}

        # If the children are transient or temporary, then we want to propagate shutdown up
        case Supervisor.child_spec({pool_config.mod, pool_args}, id: pool_idx) do
          %{restart: restart} = spec when restart in [:transient, :temporary] ->
            Map.put(spec, :significant, true)

          spec ->
            spec
        end
      end)

    Supervisor.init(specs,
      max_restarts: 1_000_000,
      auto_shutdown: :all_significant,
      strategy: :one_for_one
    )
  end
end
