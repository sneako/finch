defmodule Finch.PoolManager do
  @moduledoc false
  use GenServer

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: config.manager_name)
  end

  def init(config) do
    Enum.each(config.pools, fn
      {:default, _} -> :ok
      {shp, _} -> do_start_pools(shp, config)
      _ -> :ok
    end)

    {:ok, config}
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

  def start_pools(registry_name, shp) do
    {:ok, config} = Registry.meta(registry_name, :config)
    GenServer.call(config.manager_name, {:start_pools, shp})
  end

  def handle_call({:start_pools, shp}, _from, state) do
    reply = do_start_pools(shp, state)
    {:reply, reply, state}
  end

  defp do_start_pools(shp, config) do
    {count, size} = pool_config(config, shp)
    pool_args = {shp, config.registry_name, size}

    Enum.map(1..count, fn _ ->
      DynamicSupervisor.start_child(config.supervisor_name, {Finch.Pool, pool_args})
    end)
    |> hd()
  end

  defp pool_config(%{pools: config}, shp) do
    case Map.get(config, shp, config[:default]) do
      nil -> {1, 10}
      %{count: count, size: size} -> {count, size}
    end
  end
end
