defmodule Finch.HTTP1.PoolMetricsTest do
  use FinchCase, async: true
  use Mimic

  alias Finch.HTTP1.PoolMetrics
  alias Finch.PoolManager

  test "should not start if opt is false", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch,
       name: finch_name, pools: %{default: [protocols: [:http1], start_pool_metrics?: false]}}
    )

    shp = shp_from_bypass(bypass)

    parent = self()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      ["number", number] = String.split(conn.query_string, "=")
      send(parent, {:ping_bypass, number})
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    refs =
      Enum.map(1..1, fn i ->
        Finch.build(:get, endpoint(bypass, "?number=#{i}"))
        |> Finch.async_request(finch_name)
      end)

    assert_receive {:ping_bypass, "1"}, 500

    Enum.each(refs, fn req_ref ->
      assert_receive {^req_ref, {:status, 200}}, 2000
    end)

    wait_connection_checkin()
    assert nil == PoolManager.get_pool_count(finch_name, shp)
    assert {:error, :not_found} = Finch.get_pool_status(finch_name, shp)
    assert [] == PoolManager.get_default_shps(finch_name)
    assert {:error, :not_found} = Finch.get_pool_status(finch_name, :default)
  end

  test "get default pool status", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch,
       name: finch_name, pools: %{default: [protocols: [:http1], start_pool_metrics?: true]}}
    )

    shp = shp_from_bypass(bypass)

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    assert {:ok, %Finch.Response{status: 200}} =
             Finch.build(:get, endpoint(bypass))
             |> Finch.request(finch_name)

    wait_connection_checkin()

    assert {:ok, %{^shp => [%PoolMetrics{}]}} = Finch.get_pool_status(finch_name, :default)
  end

  test "get default pool status returns error when no pools", %{finch_name: finch_name} do
    start_supervised!(
      {Finch,
       name: finch_name, pools: %{default: [protocols: [:http1], start_pool_metrics?: true]}}
    )

    assert {:error, :not_found} = Finch.get_pool_status(finch_name, :default)
  end

  test "get pool status", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch,
       name: finch_name, pools: %{default: [protocols: [:http1], start_pool_metrics?: true]}}
    )

    shp = shp_from_bypass(bypass)

    parent = self()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      ["number", number] = String.split(conn.query_string, "=")
      send(parent, {:ping_bypass, number})

      Process.sleep(:timer.seconds(1))
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    refs =
      Enum.map(1..20, fn i ->
        Finch.build(:get, endpoint(bypass, "?number=#{i}"))
        |> Finch.async_request(finch_name)
      end)

    assert_receive {:ping_bypass, "20"}, 500

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                pool_size: 50,
                available_connections: 30,
                in_use_connections: 20
              }
            ]} = Finch.get_pool_status(finch_name, shp)

    Enum.each(refs, fn req_ref ->
      assert_receive {^req_ref, {:status, 200}}, 2000
    end)

    wait_connection_checkin()

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                pool_size: 50,
                available_connections: 50,
                in_use_connections: 0
              }
            ]} = Finch.get_pool_status(finch_name, shp)
  end

  test "get multi pool status", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{default: [protocols: [:http1], start_pool_metrics?: true, count: 2]}}
    )

    shp = shp_from_bypass(bypass)

    parent = self()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      ["number", number] = String.split(conn.query_string, "=")
      send(parent, {:ping_bypass, number})

      Process.sleep(:timer.seconds(1))
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    refs =
      Enum.map(1..20, fn i ->
        Finch.build(:get, endpoint(bypass, "?number=#{i}"))
        |> Finch.async_request(finch_name)
      end)

    assert_receive {:ping_bypass, "20"}, 500

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                available_connections: p1_available_conns,
                in_use_connections: p1_in_use_conns
              },
              %PoolMetrics{
                pool_index: 2,
                available_connections: p2_available_conns,
                in_use_connections: p2_in_use_conns
              }
            ]} = Finch.get_pool_status(finch_name, shp)

    assert p1_available_conns + p2_available_conns == 80
    assert p1_in_use_conns + p2_in_use_conns == 20

    Enum.each(refs, fn req_ref ->
      assert_receive {^req_ref, {:status, 200}}, 2000
    end)

    wait_connection_checkin()

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                available_connections: p1_available_conns,
                in_use_connections: p1_in_use_conns
              },
              %PoolMetrics{
                pool_index: 2,
                available_connections: p2_available_conns,
                in_use_connections: p2_in_use_conns
              }
            ]} = Finch.get_pool_status(finch_name, shp)

    assert p1_available_conns + p2_available_conns == 100
    assert p1_in_use_conns + p2_in_use_conns == 0
  end

  test "get pool status with not reusable connections", %{bypass: bypass, finch_name: finch_name} do
    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{
         default: [
           protocols: [:http1],
           start_pool_metrics?: true,
           conn_max_idle_time: 1,
           size: 10
         ]
       }}
    )

    shp = shp_from_bypass(bypass)

    parent = self()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      ["number", number] = String.split(conn.query_string, "=")
      send(parent, {:ping_bypass, number})
      Process.sleep(:timer.seconds(1))
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    refs =
      Enum.map(1..8, fn i ->
        ref =
          Finch.build(:get, endpoint(bypass, "?number=#{i}"))
          |> Finch.async_request(finch_name)

        {ref, i}
      end)

    assert_receive {:ping_bypass, "8"}, 500

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                pool_size: 10,
                available_connections: 2,
                in_use_connections: 8
              }
            ]} = Finch.get_pool_status(finch_name, shp)

    Enum.each(refs, fn {req_ref, _number} -> assert_receive({^req_ref, {:status, 200}}, 2000) end)

    wait_connection_checkin()

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                pool_size: 10,
                available_connections: 10,
                in_use_connections: 0
              }
            ]} = Finch.get_pool_status(finch_name, shp)

    refs =
      Enum.map(1..8, fn i ->
        ref =
          Finch.build(:get, endpoint(bypass, "?number=#{i}"))
          |> Finch.async_request(finch_name)

        {ref, i}
      end)

    assert_receive {:ping_bypass, "8"}, 500

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                pool_size: 10,
                available_connections: 2,
                in_use_connections: 8
              }
            ]} = Finch.get_pool_status(finch_name, shp)

    Enum.each(refs, fn {req_ref, _number} -> assert_receive({^req_ref, {:status, 200}}, 2000) end)

    wait_connection_checkin()

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                pool_size: 10,
                available_connections: 10,
                in_use_connections: 0
              }
            ]} = Finch.get_pool_status(finch_name, shp)
  end

  test "get pool status with raise before checkin", %{finch_name: finch_name} do
    stub(Mint.HTTP, :request, fn _, _, _, _, _ ->
      raise "unexpected error"
    end)

    start_supervised!(
      {Finch,
       name: finch_name,
       pools: %{
         default: [
           protocols: [:http1],
           start_pool_metrics?: true,
           size: 10
         ]
       }}
    )

    url = "http://raise.com"
    shp = {:http, "raise.com", 80}

    Enum.map(1..20, fn _idx ->
      assert_raise(RuntimeError, fn ->
        Finch.build(:get, url) |> Finch.request(finch_name)
      end)
    end)

    wait_connection_checkin()

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                pool_size: 10,
                available_connections: 10,
                in_use_connections: 0
              }
            ]} = Finch.get_pool_status(finch_name, shp)
  end

  defp shp_from_bypass(bypass), do: {:http, "localhost", bypass.port}

  defp wait_connection_checkin(), do: Process.sleep(5)
end
