defmodule Finch.ConfiguredPoolIdleRestartTest do
  use FinchCase, async: false

  @moduletag bypass: false

  test "start_pool/3 replaces a pool after its last worker exits for idle timeout", %{
    finch_name: finch_name
  } do
    pool = Finch.Pool.new("http://127.0.0.1:1", tag: :configured)
    pool_name = Finch.Pool.to_name(pool)
    listener = :"#{finch_name}.RegistryListener"
    Process.register(self(), listener)

    original_opts = [
      protocols: [:http1],
      size: 1,
      count: 1,
      pool_max_idle_time: 60_000,
      conn_opts: [transport_opts: [timeout: 4_321]]
    ]

    replacement_opts = [
      protocols: [:http1],
      size: 7,
      count: 1,
      pool_max_idle_time: :infinity,
      conn_opts: [transport_opts: [timeout: 9_876]]
    ]

    assert {:ok, expected_config} = Finch.cast_pool_opts(replacement_opts)

    start_supervised!({Finch, name: finch_name, pools: %{}, registry_listeners: [listener]})

    assert :ok = Finch.start_pool(finch_name, pool, original_opts)
    assert_receive {:register, ^finch_name, ^pool_name, _partition, Finch.HTTP1.Pool}, 2_000
    assert {:ok, worker} = Finch.find_pool(finch_name, pool)

    assert {pool_supervisor, ^pool_name, Finch.HTTP1.Pool, 1, original_config} =
             Finch.Pool.Manager.get_pool_supervisor(finch_name, pool)

    assert :ok = :sys.suspend(pool_supervisor)

    try do
      worker_monitor = Process.monitor(worker)
      assert :ok = GenServer.stop(worker, {:shutdown, :idle_timeout}, 2_000)

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, {:shutdown, :idle_timeout}},
                     2_000

      assert_receive {:unregister, ^finch_name, ^pool_name, _partition}, 2_000
      assert :error = Finch.find_pool(finch_name, pool)

      caller = self()

      replacement =
        Task.async(fn ->
          send(caller, {self(), :ready})

          receive do
            :start_pool -> Finch.start_pool(finch_name, pool, replacement_opts)
          end
        end)

      replacement_pid = replacement.pid
      assert_receive {^replacement_pid, :ready}

      supervisor_registry = Finch.Pool.Manager.supervisor_registry_name(finch_name)
      stale_registration = [{pool_supervisor, {Finch.HTTP1.Pool, 1, original_config}}]

      traced_functions =
        :erlang.trace_pattern(
          {Registry, :lookup, 2},
          [{:_, [], [{:return_trace}]}],
          [:local]
        )

      try do
        assert traced_functions == 1
        assert 1 = :erlang.trace(replacement_pid, true, [:call])
        send(replacement_pid, :start_pool)

        assert_receive {:trace, replacement_pid, :call,
                        {Registry, :lookup, [^supervisor_registry, ^pool_name]}},
                       2_000

        assert_receive {:trace, ^replacement_pid, :return_from, {Registry, :lookup, 2},
                        ^stale_registration},
                       2_000
      after
        disable_call_trace(replacement_pid)
        :erlang.trace_pattern({Registry, :lookup, 2}, false, [:local])
      end

      supervisor_monitor = Process.monitor(pool_supervisor)
      assert :ok = :sys.resume(pool_supervisor)

      assert_receive {:DOWN, ^supervisor_monitor, :process, ^pool_supervisor, :shutdown}, 2_000
      assert :ok = Task.await(replacement, 2_000)

      assert {:ok, replacement_worker} = Finch.find_pool(finch_name, pool)
      assert Process.alive?(replacement_worker)

      assert {replacement_supervisor, ^pool_name, Finch.HTTP1.Pool, 1, replacement_config} =
               Finch.Pool.Manager.get_pool_supervisor(finch_name, pool)

      assert replacement_config[:size] == expected_config[:size]
      assert replacement_config[:pool_max_idle_time] == expected_config[:pool_max_idle_time]

      assert replacement_config[:conn_opts][:transport_opts][:timeout] ==
               expected_config[:conn_opts][:transport_opts][:timeout]

      refute replacement_supervisor == pool_supervisor

      stop_supervised!(finch_name)
      Process.unregister(listener)
    after
      if Process.alive?(pool_supervisor), do: :sys.resume(pool_supervisor)
    end
  end

  defp disable_call_trace(pid) do
    :erlang.trace(pid, false, [:call])
  rescue
    ArgumentError -> :ok
  end
end
