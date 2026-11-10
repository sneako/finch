defmodule Finch.HTTP1.PoolIdleTerminationTest do
  # Reproduces the idle termination problems reported in
  # https://github.com/sneako/finch/issues/311 (pools that never stop),
  # https://github.com/sneako/finch/issues/291 (checkout racing the stop) and
  # https://github.com/sneako/finch/issues/393 (request racing the teardown).
  #
  # Run them alone with `mix test --only idle_termination`.
  use FinchCase, async: false

  @moduletag :idle_termination
  @moduletag capture_log: true

  @idle 50
  # An idle pool leaves the registry first and stops @idle_stop_grace_ms (1 s)
  # later, see Finch.HTTP1.Pool.
  @wait 3_000

  describe "pool_max_idle_time stops" do
    test "pools that never opened a connection", %{bypass: bypass, finch_name: finch_name} do
      start_finch!(finch_name, count: 3)
      Bypass.expect(bypass, &Plug.Conn.send_resp(&1, 200, "OK"))

      # The first request starts all three pools but opens a connection in one only.
      # It can take longer than @idle, so the two empty pools may already be gone.
      assert {:ok, %{status: 200}} = request(bypass, finch_name)
      supervisor = pool_supervisor(bypass, finch_name)
      assert %{workers: 3} = Supervisor.count_children(supervisor)
      supervisor_ref = Process.monitor(supervisor)

      assert eventually(fn -> pools(bypass, finch_name) == [] end),
             "#{length(pools(bypass, finch_name))} of 3 idle pools are still alive"

      assert_receive {:DOWN, ^supervisor_ref, :process, _, _}, @wait
    end

    test "pools whose connections the server closed", %{bypass: bypass, finch_name: finch_name} do
      start_finch!(finch_name, count: 1)

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("connection", "close")
        |> Plug.Conn.send_resp(200, "OK")
      end)

      assert {:ok, %{status: 200}} = request(bypass, finch_name)
      assert [{pool, _}] = pools(bypass, finch_name)
      pool_ref = Process.monitor(pool)

      assert eventually(fn -> pools(bypass, finch_name) == [] end),
             "the idle pool is still alive with #{worker_count(pool)} connections"

      assert_receive {:DOWN, ^pool_ref, :process, ^pool, {:shutdown, :idle_timeout}}, @wait
    end

    test "pools that had a checked out request cancelled", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_finch!(finch_name, count: 1)
      Bypass.expect(bypass, &Plug.Conn.send_resp(&1, 200, "OK"))

      # Raising inside the stream function cancels the checkout, so NimblePool
      # removes the connection without calling handle_checkin/4.
      assert_raise RuntimeError, "boom", fn ->
        Finch.build(:get, endpoint(bypass))
        |> Finch.stream(finch_name, nil, fn _, _ -> raise "boom" end)
      end

      # A later request leaves an idle connection in the pool, so the pool is
      # not empty and only the cancelled checkout can keep it alive.
      assert {:ok, %{status: 200}} = request(bypass, finch_name)
      assert [{pool, _}] = pools(bypass, finch_name)
      pool_ref = Process.monitor(pool)

      assert eventually(fn -> pools(bypass, finch_name) == [] end),
             "the idle pool is still alive with #{worker_count(pool)} connections"

      assert_receive {:DOWN, ^pool_ref, :process, ^pool, {:shutdown, :idle_timeout}}, @wait
    end
  end

  describe "a request that races the idle stop" do
    test "is served when it reaches the pool as the pool decides to stop", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_finch!(finch_name, count: 1)
      Bypass.expect(bypass, &Plug.Conn.send_resp(&1, 200, "OK"))

      assert {:ok, %{status: 200}} = request(bypass, finch_name)
      assert [{pool, _}] = pools(bypass, finch_name)

      # Hold the pool past pool_max_idle_time, until its idle timer has fired.
      # The idle check is then the next message the pool handles.
      :ok = :sys.suspend(pool)
      Process.sleep(@idle * 2)
      assert eventually(fn -> message_queue_len(pool) > 0 end)

      # The request finds the pool in the registry and queues its checkout
      # behind the idle check.
      task = Task.async(fn -> catch_request(bypass, finch_name) end)
      assert eventually(fn -> message_queue_len(pool) > 1 end)

      :ok = :sys.resume(pool)
      assert {:ok, %{status: 200}} = Task.await(task, @wait)
    end

    test "is served when it arrives while the pool supervisor shuts down", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_finch!(finch_name, count: 1)
      Bypass.expect(bypass, &Plug.Conn.send_resp(&1, 200, "OK"))

      assert {:ok, %{status: 200}} = request(bypass, finch_name)
      assert [{pool, _}] = pools(bypass, finch_name)
      supervisor = pool_supervisor(bypass, finch_name)
      pool_ref = Process.monitor(pool)
      supervisor_ref = Process.monitor(supervisor)

      # The pool stops on idle, but its supervisor cannot react yet, so the
      # supervisor stays registered while no pool is left under it.
      :ok = :sys.suspend(supervisor)
      assert_receive {:DOWN, ^pool_ref, :process, ^pool, {:shutdown, :idle_timeout}}, @wait
      assert eventually(fn -> exit_queued?(supervisor, pool) end)
      assert pools(bypass, finch_name) == []

      # The request finds the stale supervisor and waits on it. The supervisor
      # then handles the pool exit and shuts down.
      task = Task.async(fn -> catch_request(bypass, finch_name) end)

      assert eventually(fn ->
               {:messages, messages} = Process.info(supervisor, :messages)
               Enum.any?(messages, &match?({:"$gen_call", _, :which_children}, &1))
             end)

      :ok = :sys.resume(supervisor)
      assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :shutdown}, @wait
      assert {:ok, %{status: 200}} = Task.await(task, @wait)
      assert pool_supervisor(bypass, finch_name) != supervisor
    end
  end

  defp start_finch!(finch_name, pool_opts) do
    default = Keyword.merge([protocols: [:http1], pool_max_idle_time: @idle], pool_opts)
    start_supervised!({Finch, name: finch_name, pools: %{default: default}})
  end

  defp request(bypass, finch_name) do
    Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)
  end

  defp catch_request(bypass, finch_name) do
    request(bypass, finch_name)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp finch_pool(bypass), do: Finch.Pool.new(endpoint(bypass))

  defp pools(bypass, finch_name) do
    Registry.lookup(finch_name, Finch.Pool.to_name(finch_pool(bypass)))
  end

  defp pool_supervisor(bypass, finch_name) do
    registry = Finch.Pool.Manager.supervisor_registry_name(finch_name)
    [{supervisor, _}] = Registry.lookup(registry, Finch.Pool.to_name(finch_pool(bypass)))
    supervisor
  end

  defp worker_count(pool) do
    if Process.alive?(pool), do: :queue.len(:sys.get_state(pool).resources), else: 0
  end

  defp message_queue_len(pid) do
    {:message_queue_len, len} = Process.info(pid, :message_queue_len)
    len
  end

  defp exit_queued?(supervisor, pool) do
    {:messages, messages} = Process.info(supervisor, :messages)
    Enum.any?(messages, &match?({:EXIT, ^pool, _}, &1))
  end

  defp eventually(fun, timeout \\ @wait) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_eventually(fun, deadline)
    end
  end
end
