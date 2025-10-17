defmodule Finch.HTTP1.PoolTest do
  use FinchCase, async: true

  alias Finch.HTTP1Server

  setup_all do
    port = 4005
    url = "http://localhost:#{port}"

    start_supervised!({HTTP1Server, port: port})

    {:ok, url: url}
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
           pool_max_idle_time: 5
         ]
       }}
    )

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass))
             |> Finch.request(IdleFinch)

    [{_, pool, _, _}] = DynamicSupervisor.which_children(IdleFinch.PoolSupervisor)

    Process.monitor(pool)

    assert_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}

    assert [] = DynamicSupervisor.which_children(IdleFinch.PoolSupervisor)

    assert_receive :telemetry_sent

    :telemetry.detach(test_name)
  end

  @tag capture_log: true
  test "should consider last checkout timestamp on pool idle termination", %{
    bypass: bypass,
    finch_name: finch_name
  } do
    parent = self()

    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{
         default: [count: 1, size: 2, pool_max_idle_time: 200]
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
    Task.async(fn -> delay_exec.(ref1, 10) end)

    ref2 = make_ref()
    Task.async(fn -> delay_exec.(ref2, 10) end)

    assert_receive {^ref1, :done}, 150

    assert_receive {^ref2, :done}, 150

    # after here the next idle termination will trigger in =~  ms

    assert [{pool, _pool_mod}] = Registry.lookup(finch_name, shp(bypass))

    Process.monitor(pool)

    refute_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 200

    ref3 = make_ref()

    Task.async(fn -> assert {:ok, %{status: 200}} = delay_exec.(ref3, 10) end)

    assert_receive {^ref3, :done}, 150

    refute_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 200

    assert_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 200

    assert [] = DynamicSupervisor.which_children(:"#{finch_name}.PoolSupervisor")
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

    assert_receive {^ref1, :done}
    assert_receive {^ref2, :done}

    assert [{pool, _pool_mod}] = Registry.lookup(finch_name, shp(bypass))

    Process.monitor(pool)

    ref2 = make_ref()
    Task.async(fn -> delay_exec.(ref2, 1000) end)

    assert_receive {^ref2, :start}

    refute_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 1000

    assert_receive {^ref2, :done}

    assert_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}, 200

    assert [] = DynamicSupervisor.which_children(:"#{finch_name}.PoolSupervisor")
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
        Finch.build(:get, url <> "/stream/1/50")
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

  defp shp(%{port: port}), do: {:http, "localhost", port}
  defp shp({scheme, {:local, unix_socket}}), do: {scheme, {:local, unix_socket}, 0}
end
