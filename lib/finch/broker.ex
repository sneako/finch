defmodule Finch.Broker do
  @moduledoc false

  def start_link(opts \\ []) do
    :sbroker.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  def init(opts) do
    client_queue =
      {:sbroker_timeout_queue, %{
        out: :out,
        timeout: opts[:timeout] || 1_000,
        drop: :drop,
        min: 0,
        max: 128
      }}

    worker_queue =
      {:sbroker_drop_queue, %{
        out: :out_r,
        drop: :drop,
        timeout: :infinity
      }}

    {:ok, {client_queue, worker_queue, []}}
  end
end

