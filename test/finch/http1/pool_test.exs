defmodule Finch.HTTP1.PoolTest do
  use FinchCase, async: true

  alias Finch.HTTP1Server

  defmodule SlowTransport do
    def close(test_pid) do
      send(test_pid, {:closing, self()})
      Process.sleep(200)
      :ok
    end
  end

  # A TLS server behind a TCP relay that stops forwarding bytes 300 ms after
  # accepting a connection but keeps both sockets open. Closing the client
  # side then gets no answer, so :ssl.close/1 waits its full 5 s.
  defmodule SilentPeer do
    @fixtures_dir Path.expand("../../fixtures", __DIR__)

    def start do
      {:ok, tls_listen} =
        :ssl.listen(0,
          certfile: Path.join(@fixtures_dir, "selfsigned.pem"),
          keyfile: Path.join(@fixtures_dir, "selfsigned_key.pem"),
          reuseaddr: true,
          active: false
        )

      {:ok, {_, tls_port}} = :ssl.sockname(tls_listen)
      spawn_link(fn -> accept_tls(tls_listen) end)

      {:ok, relay_listen} = :gen_tcp.listen(0, active: false, mode: :binary, reuseaddr: true)
      {:ok, {_, relay_port}} = :inet.sockname(relay_listen)
      spawn_link(fn -> accept_relay(relay_listen, tls_port) end)

      "https://localhost:#{relay_port}"
    end

    defp accept_tls(listen) do
      {:ok, transport} = :ssl.transport_accept(listen)

      spawn_link(fn ->
        {:ok, socket} = :ssl.handshake(transport)
        {:ok, _request} = :ssl.recv(socket, 0, 5_000)
        :ok = :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        Process.sleep(:infinity)
      end)

      accept_tls(listen)
    end

    defp accept_relay(listen, tls_port) do
      {:ok, client} = :gen_tcp.accept(listen)
      {:ok, upstream} = :gen_tcp.connect(~c"localhost", tls_port, active: false, mode: :binary)
      deadline = System.monotonic_time(:millisecond) + 300
      spawn_link(fn -> relay(client, upstream, deadline) end)
      spawn_link(fn -> relay(upstream, client, deadline) end)
      accept_relay(listen, tls_port)
    end

    defp relay(from, to, deadline) do
      left = deadline - System.monotonic_time(:millisecond)

      with true <- left > 0,
           {:ok, data} <- :gen_tcp.recv(from, 0, left),
           :ok <- :gen_tcp.send(to, data) do
        relay(from, to, deadline)
      else
        _ -> Process.sleep(:infinity)
      end
    end
  end

  setup_all do
    port = 4005
    url = "http://localhost:#{port}"

    start_supervised!({HTTP1Server, port: port})

    {:ok, url: url}
  end

  test "closing a connection whose peer went silent does not block checkouts",
       %{finch_name: finch_name} do
    url = SilentPeer.start()

    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{
         url => [conn_max_idle_time: 10, conn_opts: [transport_opts: [verify: :verify_none]]]
       }}
    )

    assert {:ok, %{status: 200}} = Finch.build(:get, url) |> Finch.request(finch_name)

    # Long enough for the relay to have gone quiet and the connection to have
    # exceeded conn_max_idle_time. The first checkout removes it, and the pool
    # must keep serving the other while that connection is being closed.
    Process.sleep(400)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Finch.build(:get, url) |> Finch.request(finch_name, pool_timeout: 500)
        end)
      end)
      |> Task.await_many()

    assert [{:ok, %{status: 200}}, {:ok, %{status: 200}}] = results
  end

  test "terminate_worker/3 does not wait for the connection to close" do
    conn = %{mint: %Mint.HTTP1{state: :open, transport: SlowTransport, socket: self()}}
    state = %Finch.HTTP1.Pool.State{}

    started = System.monotonic_time(:millisecond)
    assert {:ok, ^state} = Finch.HTTP1.Pool.terminate_worker(:closed, conn, state)
    assert System.monotonic_time(:millisecond) - started < 100

    assert_receive {:closing, closer}
    refute closer == self()
  end

  test "closes a TLS connection removed for exceeding conn_max_idle_time", %{
    finch_name: finch_name
  } do
    test = self()

    handler = fn transport, socket ->
      :ok = transport.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
      send(test, {:peer_saw, transport.recv(socket, 0, 5_000)})
    end

    {:ok, %{url: url}} = Finch.MockSocketServer.start(transport: :ssl, handler: handler)

    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{
         url => [
           conn_max_idle_time: 10,
           conn_opts: [transport_opts: [verify: :verify_none, timeout: 200]]
         ]
       }}
    )

    assert {:ok, %{status: 200}} = Finch.build(:get, url) |> Finch.request(finch_name)
    Process.sleep(50)

    # The checkout finds the connection idle for too long and removes it. The
    # server accepts one connection, so the request itself gets no answer.
    _ = Finch.build(:get, url) |> Finch.request(finch_name)

    assert_receive {:peer_saw, {:error, :closed}}, 5_000
  end

  @tag capture_log: true
  test "should terminate pool after idle timeout", %{bypass: bypass, finch_name: finch_name} do
    test_name = to_string(finch_name)
    parent = self()

    handler = fn event, _measurements, meta, _config ->
      assert event == [:finch, :pool_max_idle_time_exceeded]
      assert is_atom(meta.scheme)
      assert is_binary(meta.host)
      assert is_integer(meta.port)
      send(parent, :telemetry_sent)
    end

    :telemetry.attach(test_name, [:finch, :pool_max_idle_time_exceeded], handler, nil)

    start_supervised!(
      {Finch,
       name: IdleFinch,
       pools: %{
         default: [
           protocols: [:http1],
           pool_max_idle_time: 50
         ]
       }}
    )

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass))
             |> Finch.request(IdleFinch)

    [{_, supervisor, _, _}] = DynamicSupervisor.which_children(IdleFinch.PoolSupervisor)
    [{_, pool, _, _}] = Supervisor.which_children(supervisor)

    Process.monitor(supervisor)
    Process.monitor(pool)

    assert_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 200
    assert_receive {:DOWN, _, :process, ^supervisor, :shutdown}, 200

    assert [] = DynamicSupervisor.which_children(IdleFinch.PoolSupervisor)
    assert_receive :telemetry_sent

    :telemetry.detach(test_name)
  end

  @tag capture_log: true
  test "should consider last checkout timestamp on pool idle termination", %{
    bypass: bypass,
    finch_name: finch_name
  } do
    idle_timeout = 60_000

    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{
         default: [count: 1, size: 2, pool_max_idle_time: idle_timeout]
       }}
    )

    Bypass.expect(bypass, &Plug.Conn.send_resp(&1, 200, "OK"))
    request = Finch.build(:get, endpoint(bypass))
    assert {:ok, %{status: 200}} = Finch.request(request, finch_name, receive_timeout: 5_000)

    pool_key = pool(bypass)
    assert [{pool, _pool_mod}] = Registry.lookup(finch_name, Finch.Pool.to_name(pool_key))

    # Age the previous checkout explicitly instead of racing real idle timers.
    # This call also waits for the request's checkin to be processed.
    old_checkout = System.monotonic_time(:millisecond) - 2 * idle_timeout

    old_state =
      :sys.replace_state(pool, fn state ->
        put_in(state.state.activity_info.last_checkout_ts, old_checkout)
      end)

    [{conn, _metadata}] = :queue.to_list(old_state.resources)
    assert old_state.state.activity_info.in_use_count == 0
    assert {:stop, :idle_timeout} = Finch.HTTP1.Pool.handle_ping(conn, old_state.state)

    assert {:ok, %{status: 200}} = Finch.request(request, finch_name, receive_timeout: 5_000)
    new_state = :sys.get_state(pool).state
    assert new_state.activity_info.in_use_count == 0
    assert new_state.activity_info.last_checkout_ts > old_checkout

    # An idle connection must not stop the pool after another checkout refreshed it.
    assert {:ok, ^conn} = Finch.HTTP1.Pool.handle_ping(conn, new_state)
  end

  # @tag capture_log: true
  test "should not terminate if a connection is checked out", %{
    bypass: bypass,
    finch_name: finch_name
  } do
    parent = self()

    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{
         default: [count: 1, size: 2, pool_max_idle_time: 100]
       }}
    )

    Bypass.expect(bypass, fn conn ->
      {"delay", str_delay} =
        Enum.find(conn.req_headers, fn h -> match?({"delay", _}, h) end)

      Process.sleep(String.to_integer(str_delay))
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    delay_exec = fn ref, delay ->
      send(parent, {ref, :start})

      resp =
        Finch.build(:get, endpoint(bypass), [{"delay", "#{delay}"}])
        |> Finch.request(finch_name)

      send(parent, {ref, :done})
      resp
    end

    ref1 = make_ref()
    ref2 = make_ref()

    Task.async(fn -> delay_exec.(ref1, 10) end)
    Task.async(fn -> delay_exec.(ref2, 10) end)

    # sometimes these messages are delayed in CI so we allow a longer wait
    assert_receive {^ref1, :done}, 500
    assert_receive {^ref2, :done}, 500

    [{_, supervisor, _, _}] = DynamicSupervisor.which_children(:"#{finch_name}.PoolSupervisor")
    Process.monitor(supervisor)

    pool_key = pool(bypass)
    assert [{pool, _pool_mod}] = Registry.lookup(finch_name, Finch.Pool.to_name(pool_key))
    Process.monitor(pool)

    ref2 = make_ref()
    Task.async(fn -> delay_exec.(ref2, 1000) end)

    assert_receive {^ref2, :start}
    refute_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 1000

    assert_receive {^ref2, :done}
    assert_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 200

    assert_receive {:DOWN, _, :process, ^supervisor, :shutdown}, 200
  end

  describe "async_request" do
    @describetag bypass: false

    setup %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name, pools: %{default: [protocols: [:http1]]}})
      :ok
    end

    test "sends responses to the caller", %{finch_name: finch_name, url: url} do
      request_ref =
        Finch.build(:get, url <> "/stream/5/5")
        |> Finch.async_request(finch_name)

      assert_receive {^request_ref, {:status, 200}}, 500
      assert_receive {^request_ref, {:headers, headers}} when is_list(headers)
      for _ <- 1..5, do: assert_receive({^request_ref, {:data, _}})
      assert_receive {^request_ref, :done}
    end

    test "sends errors to the caller", %{finch_name: finch_name, url: url} do
      request_ref =
        Finch.build(:get, url <> "/wait/100")
        |> Finch.async_request(finch_name, receive_timeout: 10)

      assert_receive {^request_ref, {:error, %{reason: :timeout}}}, 500
    end

    test "canceled with cancel_async_request/1", %{
      finch_name: finch_name,
      url: url
    } do
      ref =
        Finch.build(:get, url <> "/stream/1/100")
        |> Finch.async_request(finch_name)

      assert_receive {^ref, {:status, 200}}, 500
      Finch.HTTP1.Pool.cancel_async_request(ref)
      refute_receive {^ref, {:data, _}}
    end

    test "canceled if calling process exits normally", %{finch_name: finch_name, url: url} do
      outer = self()

      spawn(fn ->
        ref =
          Finch.build(:get, url <> "/stream/5/500")
          |> Finch.async_request(finch_name)

        # allow process to exit normally after sending
        send(outer, ref)
      end)

      assert_receive {Finch.HTTP1.Pool, pid} when is_pid(pid)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}, 500
    end

    test "canceled if calling process exits abnormally", %{finch_name: finch_name, url: url} do
      outer = self()

      caller =
        spawn(fn ->
          ref =
            Finch.build(:get, url <> "/stream/5/500")
            |> Finch.async_request(finch_name)

          send(outer, ref)

          # ensure process stays alive until explicitly exited
          Process.sleep(:infinity)
        end)

      assert_receive {Finch.HTTP1.Pool, pid} when is_pid(pid)

      ref = Process.monitor(pid)
      Process.exit(caller, :shutdown)
      assert_receive {:DOWN, ^ref, _, _, _}, 500
    end
  end

  defp pool(%{port: port}), do: Finch.Pool.from_name({:http, "localhost", port, :default})
end
