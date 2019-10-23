defmodule Finch.Worker do
  use GenServer

  alias Finch.Broker

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def init([]) do
    state = ask(%{
      tag: make_ref()
    })

    {:ok, state}
  end

  def handle_info({tag, {:go, ref, {pid, {:fetch, params}}, _, _}}, %{tag: tag}=s) do
    send(pid, {ref, do_request(params)})
    {:noreply, ask(s)}
  end

  def ask(%{tag: tag}=s) do
    {:await, ^tag, _} = :sbroker.async_ask_r(Broker, self(), {self(), tag})
    s
  end

  def do_request(params) do
    Process.sleep(1_000)
    {:ok, "External service called with #{inspect(params)}"}
  end
end
