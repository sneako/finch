defmodule Finch.PoolManager do
  @moduledoc false
  use GenServer

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: config.manager_name)
  end

  @impl true
  def init(config) do
    Enum.each(config.pools, fn {shp, _} ->
      do_start_pools(shp, config)
    end)

    {:ok, config}
  end

  def get_pool(registry_name, {_scheme, _host, _port} = key) do
    case lookup_pool(registry_name, key) do
      {pid, _}=pool when is_pid(pid) ->
        pool

      :none ->
        start_pools(registry_name, key)
    end
  end

  def lookup_pool(registry, key) do
    case Registry.lookup(registry, key) do
      [] ->
        :none

      [pool] ->
        pool

      pools ->
        # TODO implement alternative strategies
        Enum.random(pools)
    end
  end

  def start_pools(registry_name, shp) do
    {:ok, config} = Registry.meta(registry_name, :config)
    GenServer.call(config.manager_name, {:start_pools, shp})
  end

  @impl true
  def handle_call({:start_pools, shp}, _from, state) do
    reply =
      case lookup_pool(state.registry_name, shp) do
        :none -> do_start_pools(shp, state)
        pool -> pool
      end

    {:reply, reply, state}
  end

  defp do_start_pools(shp, config) do
    pool_config = pool_config(config, shp)
    pool_args   = {shp, config.registry_name, pool_config.size, pool_config}
    pool_mod    = pool_mod(pool_config.scheme)

    Enum.map(1..pool_config.count, fn _ ->
      # Choose pool type here...
      {:ok, pid} = DynamicSupervisor.start_child(config.supervisor_name, {pool_mod, pool_args})
      {pid, pool_mod}
    end)
    |> hd()
  end

  defp pool_config(%{pools: config, default_pool_config: default}, shp) do
    case Map.get(config, shp, config[:default]) do
      nil -> default
      config -> config
    end
  end

  defp pool_mod(:http1), do: Finch.HTTP1.Pool
  defp pool_mod(:http2), do: Finch.HTTP2.Pool
end
