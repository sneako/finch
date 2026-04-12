defmodule Finch.ViaCleaner do
  @moduledoc false
  use GenServer

  # A tiny GenServer added as a child of the Finch supervision tree when
  # the Finch instance is named with a `{:via, Registry, _}` tuple.
  #
  # Its only job is to remove the ETS mapping entry in `Finch.NameRegistry`
  # when the Finch supervision tree shuts down, preventing stale entries.

  @spec start_link({:via, Registry, {atom(), term()}}) :: GenServer.on_start()
  def start_link(via_name) do
    GenServer.start_link(__MODULE__, via_name)
  end

  @impl true
  def init(via_name) do
    Process.flag(:trap_exit, true)
    {:ok, via_name}
  end

  @impl true
  def terminate(_reason, via_name) do
    Finch.NameRegistry.unregister(via_name)
    :ok
  end
end
