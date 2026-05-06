defmodule Finch.Pool.Supervisor do
  @moduledoc false

  # Supervisor each process in a pool (effectively one child per pool_config.count)
  alias Finch.Pool
  use Supervisor, restart: :transient

  @type pool_idx() :: pos_integer()

  def start_link({name, arg}) do
    Supervisor.start_link(__MODULE__, arg, name: name)
  end

  def init({registry_name, pool, pool_config, track_default?}) do
    pool_name = Pool.to_name(pool)

    if track_default? do
      Registry.register(registry_name, :default, {pool_name, pool_config.mod})
    end

    specs =
      Enum.map(1..pool_config.count, &build_child_spec(pool, registry_name, pool_config, &1))

    Supervisor.init(specs, auto_shutdown: :all_significant, strategy: :one_for_one)
  end

  @spec set_count(pid(), Pool.t(), Finch.name(), map(), pos_integer(), pos_integer()) ::
          :ok | {:error, {pool_idx(), term()}}
  def set_count(sup_pid, pool, registry_name, pool_config, old_count, new_count) do
    cond do
      new_count > old_count ->
        Enum.reduce_while((old_count + 1)..new_count, :ok, fn pool_idx, :ok ->
          spec = build_child_spec(pool, registry_name, pool_config, pool_idx)

          case Supervisor.start_child(sup_pid, spec) do
            {:ok, _pid} -> {:cont, :ok}
            {:error, {:already_started, _pid}} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {pool_idx, reason}}}
          end
        end)

      new_count < old_count ->
        Enum.reduce_while(old_count..(new_count + 1)//-1, :ok, fn pool_idx, :ok ->
          with :ok <- Supervisor.terminate_child(sup_pid, pool_idx),
               :ok <- Supervisor.delete_child(sup_pid, pool_idx) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, {pool_idx, reason}}}
          end
        end)

      true ->
        :ok
    end
  end

  @spec build_child_spec(Pool.t(), Finch.name(), map(), pool_idx()) :: Supervisor.child_spec()
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
