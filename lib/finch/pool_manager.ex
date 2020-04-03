defmodule Finch.PoolManager do
  @moduledoc false
  use Supervisor

  def start_link(name, config) do
    Supervisor.start_link(__MODULE__, config, name: name)
  end

  def get_pool(%{pool_reg_name: registry} = config, scheme, host, port) do
    key = {scheme, host, port}
    case lookup_pool(registry, key) do
      :none ->
        case start_pools(config, key) do
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
        {pid, _} = Enum.random(pids)
        {:ok, pid}
    end
  end

  def start_pools(%{pool_reg_name: registry, pool_sup_name: supervisor} = config, key) do
    {count, size} = pool_config(config, key)
    pool_args = {key, registry, size}

    Enum.map(1..count, fn _ ->
      DynamicSupervisor.start_child(supervisor, {Finch.Pool, pool_args})
    end)
    |> hd()
  end

  def init(%{pool_reg_name: registry, pool_sup_name: supervisor}) do
    children = [
      {DynamicSupervisor, name: supervisor, strategy: :one_for_one},
      {Registry, [keys: :duplicate, name: registry]},
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
