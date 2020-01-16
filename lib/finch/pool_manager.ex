defmodule Finch.PoolManager do
  @moduledoc false
  use Supervisor

  alias Finch.PoolSup
  alias Finch.PoolRegistry

  def start_link(init_args) do
    Supervisor.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  def get_pool(host) do
    case lookup_pool(host) do
      :none ->
        case start_pool(host) do
          {:ok, pid} ->
            pid

          {:error, {:already_started, pid}} ->
            pid
        end

      {:ok, pid} ->
        pid
    end
  end

  def lookup_pool(host) do
    case Registry.lookup(PoolRegistry, host) do
      [] ->
        :none

      [{pid, _}] ->
        {:ok, pid}
    end
  end

  def start_pool(host) do
    DynamicSupervisor.start_child(PoolSup, {Finch.Pool, host})
  end

  def init(_) do
    children = [
      {DynamicSupervisor, name: PoolSup, strategy: :one_for_one},
      {Registry, [keys: :unique, name: PoolRegistry]},
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
