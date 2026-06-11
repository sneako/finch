defmodule Finch.TestHelper do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  def ssl_version() do
    Application.spec(:ssl, :vsn)
    |> List.to_string()
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
  end

  @doc """
  Starts a Finch instance and waits for at least one HTTP/2 pool to register
  (enter the :connected state) before returning. Uses Registry listeners for
  deterministic readiness detection instead of polling with real requests.
  """
  def start_finch!(opts) do
    name = Keyword.fetch!(opts, :name)
    listener = :"finch_test_#{System.unique_integer([:positive])}"
    test_pid = self()
    ref = make_ref()

    listener_pid =
      spawn(fn ->
        Process.register(self(), listener)
        send(test_pid, {ref, :ready})

        receive do
          {:monitor_registry, registry_pid} ->
            registry_ref = Process.monitor(registry_pid)
            # Keep the named listener alive until the registry exits. Registry sends to
            # listener names, and sending to an unregistered atom raises.
            forward_registry_events(test_pid, registry_ref)
        end
      end)

    assert_receive {^ref, :ready}
    opts = Keyword.put(opts, :registry_listeners, [listener])
    start_supervised!({Finch, opts})
    send(listener_pid, {:monitor_registry, Process.whereis(name)})
    assert_receive {:register, ^name, _key, _pid, _value}, 5_000
    name
  end

  defp forward_registry_events(test_pid, registry_ref) do
    receive do
      {:DOWN, ^registry_ref, :process, _pid, _reason} ->
        :ok

      message ->
        send(test_pid, message)
        drain_registry_events(registry_ref)
    end
  end

  defp drain_registry_events(registry_ref) do
    receive do
      {:DOWN, ^registry_ref, :process, _pid, _reason} ->
        :ok

      _message ->
        drain_registry_events(registry_ref)
    end
  end
end
