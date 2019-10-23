defmodule Finch.Supervisor do
  use Supervisor

  alias Finch.{Broker, Worker}

  def start_link do
    Supervisor.start_link(__MODULE__, [])
  end

  def init(_args) do
    pool_size = 5
    broker = worker(Broker, [], id: :broker)

    workers = for id <- 1..pool_size do
      worker(Worker, [], id: id)
    end

    worker_sup_opts = [strategy: :one_for_one, max_restarts: pool_size]
    worker_sup = supervisor(Supervisor, [workers, worker_sup_opts], id: :workers)

    supervise([broker, worker_sup], strategy: :one_for_one)
  end
end
