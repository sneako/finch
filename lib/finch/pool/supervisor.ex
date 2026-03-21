defmodule Finch.Pool.Supervisor do
  @moduledoc false

  # Supervisor each process in a pool (effectively one child per pool_config.count)
  alias Finch.Pool
  use Supervisor, restart: :transient

  def start_link({name, arg}) do
    Supervisor.start_link(__MODULE__, arg, name: name)
  end

  def init({registry_name, pool, pool_config, track_default?}) do
    pool_name = Pool.to_name(pool)

    if track_default? do
      Registry.register(registry_name, :default, {pool_name, pool_config.mod, pool_config.count})
    end

    specs =
      Enum.map(1..pool_config.count, &build_child_spec(pool, registry_name, pool_config, &1))

    Supervisor.init(specs, auto_shutdown: :all_significant, strategy: :one_for_one)
  end

  def set_count(sup_pid, pool, registry_name, pool_config, old_count, new_count) do
    cond do
      new_count > old_count ->
        for pool_idx <- (old_count + 1)..new_count do
          spec = build_child_spec(pool, registry_name, pool_config, pool_idx)
          Supervisor.start_child(sup_pid, spec)
        end

        :ok

      new_count < old_count ->

        for pool_idx <- old_count..(new_count + 1)//-1 do
          Supervisor.terminate_child(sup_pid, pool_idx)
          Supervisor.delete_child(sup_pid, pool_idx)
        end

        :ok

      true ->
        :ok
    end
  end

  defp build_child_spec(pool, registry_name, pool_config, pool_idx) do
    pool_name = Pool.to_name(pool)
    pool_args = {pool, pool_name, registry_name, pool_config, pool_idx}

    # If the children are transient or temporary, then we want to propagate shutdown up
    case Supervisor.child_spec({pool_config.mod, pool_args}, id: pool_idx) do
      %{restart: restart} = spec when restart in [:transient, :temporary] ->
        Map.put(spec, :significant, true)

      spec ->
        spec
    end
  end
end
