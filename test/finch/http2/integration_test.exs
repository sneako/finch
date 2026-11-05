defmodule Finch.HTTP2.IntegrationTest do
  use ExUnit.Case, async: false

  alias Finch.MockHTTP2Server
  alias Finch.TestHelper

  import Mint.HTTP2.Frame, only: [headers: 1, rst_stream: 1, set_flags: 2]

  @moduletag :capture_log

  setup_all do
    {:ok, url: Application.get_env(:finch, :test_https_h2_url)}
  end

  test "routes synchronous and asynchronous requests around a saturated worker" do
    {url, server_a} =
      MockHTTP2Server.start_and_connect_with(
        [server_settings: [max_concurrent_streams: 1]],
        fn port ->
          url = "https://localhost:#{port}"

          start_supervised!(
            {Finch,
             name: TestFinch,
             pools: %{
               url => [
                 protocols: [:http2],
                 count: 2,
                 conn_opts: [transport_opts: [verify: :verify_none]]
               ]
             }}
          )

          url
        end
      )

    server_b = MockHTTP2Server.accept_socket(server_a)
    pool = Finch.Pool.new(url)
    {supervisor, _, _, _, _} = Finch.Pool.Manager.get_pool_supervisor(TestFinch, pool)
    workers = for {_, pid, :worker, _} <- Supervisor.which_children(supervisor), do: pid
    {:ok, server_peer} = :ssl.peername(server_a.socket)

    worker_a =
      Enum.find(workers, fn pid ->
        {:connected, state} = :sys.get_state(pid)
        assert state.metrics_ref == nil
        {:ok, address} = :ssl.sockname(Mint.HTTP2.get_socket(state.conn))
        address == server_peer
      end)

    worker_b = Enum.find(workers, &(&1 != worker_a))
    request = Finch.build(:get, url)
    us = self()

    strategy = fn entries ->
      send(us, :selected)

      assert Enum.sort(entries) ==
               Enum.sort([{worker_a, Finch.HTTP2.Pool}, {worker_b, Finch.HTTP2.Pool}])

      {worker_a, Finch.HTTP2.Pool}
    end

    opts = [pool_strategy: strategy]

    held = Finch.async_request(request, TestFinch, opts)
    assert_receive :selected
    assert [headers(stream_id: held_stream_id)] = MockHTTP2Server.recv_next_frames(server_a, 1)

    task = Task.async(fn -> Finch.request(request, TestFinch, opts) end)
    assert_receive :selected
    assert [headers(stream_id: stream_id)] = MockHTTP2Server.recv_next_frames(server_b, 1)
    {server_b, hbf} = MockHTTP2Server.encode_headers(server_b, [{":status", "200"}])

    MockHTTP2Server.send_frames(server_b, [
      headers(
        stream_id: stream_id,
        hbf: hbf,
        flags: set_flags(:headers, [:end_headers, :end_stream])
      )
    ])

    assert {:ok, %Finch.Response{status: 200}} = Task.await(task)

    ref = Finch.async_request(request, TestFinch, opts)
    assert_receive :selected
    assert {Finch.HTTP2.Pool, {^worker_b, _}} = ref
    assert [headers(stream_id: stream_id)] = MockHTTP2Server.recv_next_frames(server_b, 1)

    assert {:error, %Finch.HTTPError{reason: :too_many_concurrent_requests}} =
             Finch.request(request, TestFinch, opts)

    assert_receive :selected
    assert :ok = Finch.cancel_async_request(ref)
    assert [rst_stream(stream_id: ^stream_id)] = MockHTTP2Server.recv_next_frames(server_b, 1)
    assert :ok = Finch.cancel_async_request(held)

    assert [rst_stream(stream_id: ^held_stream_id)] =
             MockHTTP2Server.recv_next_frames(server_a, 1)

    ref = Finch.async_request(request, TestFinch, opts)
    assert_receive :selected
    assert {Finch.HTTP2.Pool, {^worker_a, _}} = ref
    assert [headers(stream_id: _)] = MockHTTP2Server.recv_next_frames(server_a, 1)
    Finch.cancel_async_request(ref)
    refute_receive :selected
  end

  test "capacity probes tolerate a stale worker and share one timeout" do
    start_supervised!({Registry, keys: :duplicate, name: TestFinch})
    pool = Finch.Pool.new("https://localhost")
    key = Finch.Pool.to_name(pool)
    us = self()

    workers =
      for _ <- 1..4 do
        pid =
          spawn(fn ->
            Registry.register(TestFinch, key, Finch.HTTP2.Pool)
            send(us, {:registered, self()})

            receive do
              :stop -> :ok
            end
          end)

        assert_receive {:registered, ^pid}
        pid
      end

    on_exit(fn -> Enum.each(workers, &Process.exit(&1, :kill)) end)
    [stale | _] = workers

    strategy = fn entries ->
      assert {stale, Finch.HTTP2.Pool} in entries
      monitor = Process.monitor(stale)
      Process.exit(stale, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^stale, :killed}
      {stale, Finch.HTTP2.Pool}
    end

    started = System.monotonic_time(:millisecond)

    assert {^stale, Finch.HTTP2.Pool} =
             Finch.Pool.Manager.get_pool(TestFinch, pool,
               pool_strategy: strategy,
               pool_timeout: 100
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 90
    assert elapsed < 250
  end

  test "HTTP/1 selection and single workers do not perform capacity probes" do
    start_supervised!({Registry, keys: :duplicate, name: TestFinch})
    pool = Finch.Pool.new("http://localhost")
    key = Finch.Pool.to_name(pool)
    Registry.register(TestFinch, key, Finch.HTTP1.Pool)
    selected = {self(), Finch.HTTP1.Pool}
    assert Finch.Pool.Manager.get_pool(TestFinch, pool) == selected

    us = self()

    worker =
      spawn(fn ->
        Registry.register(TestFinch, key, Finch.HTTP2.Pool)
        send(us, :registered)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive :registered

    assert Finch.Pool.Manager.get_pool(TestFinch, pool, pool_strategy: fn _ -> selected end) ==
             selected

    refute_receive {:"$gen_call", _, :available?}
  end

  test "sends http2 requests", %{url: url} do
    TestHelper.start_finch!(
      name: TestFinch,
      pools: %{
        url => [
          protocols: [:http2],
          count: 5,
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ]
        ]
      }
    )

    assert {:ok, response} = Finch.build(:get, url) |> Finch.request(TestFinch)
    assert response.body == "Hello world!"
  end

  test "sends the first request through a dynamically started pool", %{url: url} do
    start_supervised!(
      {Finch,
       name: TestFinch,
       pools: %{
         default: [
           protocols: [:http2],
           conn_opts: [transport_opts: [verify: :verify_none]]
         ]
       }}
    )

    assert {:ok, response} = Finch.build(:get, url) |> Finch.request(TestFinch)
    assert response.body == "Hello world!"
  end

  test "sends concurrent first requests through a dynamically started pool", %{url: url} do
    start_supervised!(
      {Finch,
       name: TestFinch,
       pools: %{
         default: [
           protocols: [:http2],
           conn_opts: [transport_opts: [verify: :verify_none]]
         ]
       }}
    )

    results =
      Task.async_stream(
        1..10,
        fn _ -> Finch.build(:get, url) |> Finch.request(TestFinch) end,
        max_concurrency: 10
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %Finch.Response{status: 200}}}, &1))
  end

  test "releases all callers when a dynamically started pool receives server settings" do
    start_finch_waiting_for_server_settings!()

    {request_tasks, server} =
      MockHTTP2Server.start_and_connect_with([defer_settings: true], fn port ->
        pool = Finch.Pool.new("https://localhost:#{port}")

        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            Finch.Pool.Manager.get_pool(TestFinch, pool, pool_timeout: 1_000)
          end)
        end)
      end)

    Enum.each(request_tasks, fn task -> refute Task.yield(task, 20) end)
    :ok = MockHTTP2Server.send_server_settings(server)

    Enum.each(request_tasks, fn task ->
      assert {pool, Finch.HTTP2.Pool} = Task.await(task, 1_000)
      assert is_pid(pool)
    end)
  end

  test "times out waiting for a dynamically started pool" do
    start_finch_waiting_for_server_settings!()

    {request_task, _server} =
      MockHTTP2Server.start_and_connect_with([defer_settings: true], fn port ->
        request = Finch.build(:get, "https://localhost:#{port}")

        Task.async(fn ->
          started = System.monotonic_time(:millisecond)
          result = Finch.request(request, TestFinch, pool_timeout: 50)
          elapsed = System.monotonic_time(:millisecond) - started
          {result, elapsed}
        end)
      end)

    assert {{:error, %Finch.Error{reason: :pool_not_available}}, elapsed} =
             Task.await(request_task, 1_000)

    assert elapsed >= 40
  end

  for timeout <- [1_000, :infinity] do
    test "waits for a replacement pool with pool_timeout #{inspect(timeout)}" do
      start_finch_waiting_for_server_settings!()

      {{task, pool}, server} =
        MockHTTP2Server.start_and_connect_with([defer_settings: true], fn port ->
          pool = Finch.Pool.new("https://localhost:#{port}")

          task =
            Task.async(fn ->
              Finch.Pool.Manager.get_pool(TestFinch, pool, pool_timeout: unquote(timeout))
            end)

          {task, pool}
        end)

      old_pool = waiting_pool(pool)
      Process.exit(old_pool, :kill)
      _server = MockHTTP2Server.accept_socket(server)

      assert {new_pool, Finch.HTTP2.Pool} = Task.await(task, 500)
      assert new_pool != old_pool
    end
  end

  test "pool restarts do not reset the readiness timeout" do
    start_finch_waiting_for_server_settings!()

    {{task, pool}, _server} =
      MockHTTP2Server.start_and_connect_with([defer_settings: true], fn port ->
        pool = Finch.Pool.new("https://localhost:#{port}")

        task =
          Task.async(fn ->
            Finch.Pool.Manager.get_pool(TestFinch, pool, pool_timeout: 1_000)
          end)

        {task, pool}
      end)

    old_pool = waiting_pool(pool)
    refute Task.yield(task, 750)
    Process.exit(old_pool, :kill)

    # Leave the replacement waiting for its handshake. Only the time remaining
    # from the original timeout should be available to it.
    assert :not_ready = Task.await(task, 500)
  end

  test "sends the query string", %{url: url} do
    TestHelper.start_finch!(
      name: TestFinch,
      pools: %{
        url => [
          protocols: [:http2],
          count: 5,
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ]
        ]
      }
    )

    query_string = URI.encode_query(test: true, these: "params")
    url = url <> "/query?" <> query_string

    assert {:ok, response} = Finch.build(:get, url) |> Finch.request(TestFinch)
    assert response.body == query_string
  end

  test "multiplexes requests over a single pool", %{url: url} do
    TestHelper.start_finch!(
      name: TestFinch,
      pools: %{
        url => [
          protocols: [:http2],
          count: 1,
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ]
        ]
      }
    )

    # We create multiple requests here using a single connection. There is a delay
    # in the response. But because we allow each request to run simultaneously
    # they shouldn't block each other which we check with a rough time estimates
    request = Finch.build(:get, url <> "/wait/1000")

    results =
      1..50
      |> Enum.map(fn _ ->
        Task.async(fn ->
          start = System.monotonic_time()
          {:ok, _} = Finch.request(request, TestFinch)
          System.monotonic_time() - start
        end)
      end)
      |> Enum.map(&Task.await/1)

    for result <- results do
      time = System.convert_time_unit(result, :native, :millisecond)
      assert time <= 1200
    end
  end

  @tag skip: TestHelper.ssl_version() < [10, 2]
  test "writes TLS secrets to SSLKEYLOGFILE file", %{url: url} do
    tmp_dir = System.tmp_dir()
    log_file = Path.join(tmp_dir, "ssl-key-file.log")
    :ok = System.put_env("SSLKEYLOGFILE", log_file)

    TestHelper.start_finch!(
      name: TestFinch,
      pools: %{
        url => [
          protocols: [:http2],
          count: 5,
          conn_opts: [
            transport_opts: [
              verify: :verify_none,
              keep_secrets: true,
              versions: [:"tlsv1.2", :"tlsv1.3"]
            ]
          ]
        ]
      }
    )

    try do
      assert {:ok, response} = Finch.build(:get, url) |> Finch.request(TestFinch)
      assert response.body == "Hello world!"
      assert File.stat!(log_file).size > 0
    after
      File.rm!(log_file)
      System.delete_env("SSLKEYLOGFILE")
    end
  end

  test "cancel streaming response", %{url: url} do
    TestHelper.start_finch!(
      name: TestFinch,
      pools: %{
        url => [
          protocols: [:http2],
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ]
        ]
      }
    )

    assert catch_throw(
             Finch.stream(
               Finch.build(:get, url <> "/stream/1/500"),
               TestFinch,
               :ok,
               fn {:status, _}, :ok ->
                 throw(:error)
               end
             )
           ) == :error

    refute_receive _
  end

  test "cancel completed streaming response", %{url: url} do
    TestHelper.start_finch!(
      name: TestFinch,
      pools: %{
        url => [
          protocols: [:http2],
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ]
        ]
      }
    )

    assert catch_throw(
             Finch.stream(
               Finch.build(:get, url),
               TestFinch,
               :ok,
               fn
                 {:data, _}, :ok -> throw(:error)
                 _, :ok -> :ok
               end
             )
           ) == :error

    refute_receive _
  end

  defp waiting_pool(pool) do
    {supervisor, _, _, _, _} = Finch.Pool.Manager.get_pool_supervisor(TestFinch, pool)
    [{_, pid, _, _}] = Supervisor.which_children(supervisor)

    assert eventually(fn ->
             {_, data} = :sys.get_state(pid)
             length(data.awaiting_ready) == 1
           end)

    pid
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp start_finch_waiting_for_server_settings! do
    start_supervised!(
      {Finch,
       name: TestFinch,
       pools: %{
         default: [
           protocols: [:http2],
           conn_opts: [transport_opts: [verify: :verify_none]],
           http2: [wait_for_server_settings?: true]
         ]
       }}
    )
  end
end
