defmodule Finch.HTTP1.PoolTest do
  use FinchCase, async: true

  alias Finch.HTTP1Server

  @tag capture_log: true
  test "should terminate pool after idle timeout", %{bypass: bypass, finch_name: finch_name} do
    test_name = to_string(finch_name)
    parent = self()

    handler = fn event, _measurments, meta, _config ->
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
           protocol: :http1,
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

  describe "async_request" do
    @describetag bypass: false

    setup %{finch_name: finch_name} do
      port = 4005
      endpoint = "http://localhost:#{port}"

      start_supervised!({HTTP1Server, port: port})
      start_supervised!({Finch, name: finch_name, pools: %{default: [protocol: :http1]}})

      {:ok, endpoint: endpoint}
    end

    test "sends responses to the caller", %{finch_name: finch_name, endpoint: endpoint} do
      request_ref =
        Finch.build(:get, endpoint <> "/stream/5/5")
        |> Finch.async_request(finch_name)

      assert_receive {^request_ref, {:status, 200}}
      assert_receive {^request_ref, {:headers, headers}} when is_list(headers)
      for _ <- 1..5, do: assert_receive({^request_ref, {:data, _}})
      assert_receive {^request_ref, :done}
    end

    test "sends errors to the caller", %{finch_name: finch_name, endpoint: endpoint} do
      request_ref =
        Finch.build(:get, endpoint <> "/wait/100")
        |> Finch.async_request(finch_name, receive_timeout: 10)

      assert_receive {^request_ref, {:error, %{reason: :timeout}}}
    end

    test "canceled with cancel_async_request/1", %{
      finch_name: finch_name,
      endpoint: endpoint
    } do
      ref =
        Finch.build(:get, endpoint <> "/stream/1/50")
        |> Finch.async_request(finch_name)

      assert_receive {^ref, {:status, 200}}
      Finch.HTTP1.Pool.cancel_async_request(ref)
      refute_receive {^ref, {:data, _}}
    end

    test "canceled if calling process exits", %{finch_name: finch_name, endpoint: endpoint} do
      outer = self()

      caller =
        spawn(fn ->
          {_, _, _, pid} =
            Finch.build(:get, endpoint <> "/stream/5/50")
            |> Finch.async_request(finch_name)

          send(outer, {:req_pid, pid})
        end)

      assert_receive {:req_pid, pid}

      Process.exit(caller, :kill)
      Process.sleep(100)

      refute Process.alive?(pid)
    end
  end
end
