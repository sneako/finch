defmodule Finch do
  @moduledoc """
  Documentation for Finch.
  """

  alias Finch.Broker

  @doc """
  Hello world.

  ## Examples

      iex> Finch.hello()
      :world

  """
  def hello do
    :world
  end

  def perform(params \\ %{}) do
    case :sbroker.ask(Broker, {self(), {:fetch, params}}) do
      {:go, ref, worker, _, _queue_time} ->
        monitor = Process.monitor(worker)

        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, _, _, reason} ->
            exit({reason, {__MODULE__, params}})
        end

      {:drop, _time} ->
        {:error, :overload}
    end
  end
end
