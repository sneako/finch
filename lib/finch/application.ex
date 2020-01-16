defmodule Finch.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    children = [
      Finch.PoolManager
    ]

    opts = [strategy: :one_for_one, name: Finch.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
