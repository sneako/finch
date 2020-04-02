defmodule Finch.PoolManager do
  @moduledoc false
  use Supervisor

  alias Finch.PoolSup
  alias Finch.PoolRegistry

  def start_link(init_args) do
    Supervisor.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  def get_pool(scheme, host, port) do
    key = {scheme, host, port}
    case lookup_pool(key) do
      :none ->
        case start_pools(key) do
          {:ok, pid} ->
            pid

          {:error, {:already_started, pid}} ->
            pid
        end

      {:ok, pid} ->
        pid
    end
  end

  def lookup_pool(key) do
    case Registry.lookup(PoolRegistry, key) do
      [] ->
        :none

      [{pid, _}] ->
        {:ok, pid}

      pids ->
        {pid, _} = Enum.random(pids)
        {:ok, pid}
    end
  end

  def start_pools(key) do
    # TODO avoid application env, ideally we can configure this per {s, h, p}
    pool_count = Application.get_env(:finch, :pool_count, 2)
    Enum.map(1..pool_count, fn _ ->
      DynamicSupervisor.start_child(PoolSup, {Finch.Pool, key})
    end)
    |> hd()
  end

  def init(_) do
    children = [
      {DynamicSupervisor, name: PoolSup, strategy: :one_for_one},
      {Registry, [keys: :duplicate, name: PoolRegistry]},
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
