defmodule Finch.PoolManager do
  @moduledoc false
  use Supervisor

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: config.manager_name)
  end

  def get_pool(registry_name, scheme, host, port) do
    key = {scheme, host, port}

    case lookup_pool(registry_name, key) do
      :none ->
        case start_pools(registry_name, key) do
          {:ok, pid} ->
            pid

          {:error, {:already_started, pid}} ->
            pid
        end

      {:ok, pid} ->
        pid
    end
  end

  def lookup_pool(registry, key) do
    case Registry.lookup(registry, key) do
      [] ->
        :none

      [{pid, _}] ->
        {:ok, pid}

      pids ->
        # TODO implement alternative strategies
        {pid, _} = Enum.random(pids)
        {:ok, pid}
    end
  end

  def start_pools(registry_name, key) do
    with {:ok, config} = Registry.meta(registry_name, :config) do
      {count, size} = pool_config(config, key)
      pool_args = {key, config.registry_name, size}

      Enum.map(1..count, fn _ ->
        DynamicSupervisor.start_child(config.supervisor_name, {Finch.Pool, pool_args})
      end)
      |> hd()
    end
  end

  def init(config) do
    children = [
      {DynamicSupervisor, name: config.supervisor_name, strategy: :one_for_one},
      {Registry, [keys: :duplicate, name: config.registry_name, meta: [config: config]]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pool_config(%{pools: config}, shp) do
    case Map.get(config, shp, config[:default]) do
      nil -> {1, 10}
      %{count: count, size: size} -> {count, size}
    end
  end
end
