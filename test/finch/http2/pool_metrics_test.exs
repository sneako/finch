defmodule Finch.HTTP2.PoolMetricsTest do
  use ExUnit.Case

  alias Finch.HTTP2.PoolMetrics

  setup_all do
    {:ok, url: Application.get_env(:finch, :test_https_h2_url)}
  end

  test "do not start metrics when opt is false", %{test: finch_name, url: url} do
    Finch.TestHelper.start_finch!(
      name: finch_name,
      pools: %{
        url => [
          protocols: [:http2],
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ],
          start_pool_metrics?: false
        ]
      }
    )

    {:ok, %{status: 200, body: "Hello world!"}} =
      Finch.build(:get, "#{url}/")
      |> Finch.request(finch_name)

    assert {:error, :not_found} = Finch.get_pool_status(finch_name, url)
  end

  test "get pool status async requests", %{test: finch_name, url: url} do
    parent = self()

    Finch.TestHelper.start_finch!(
      name: finch_name,
      pools: %{
        url => [
          protocols: [:http2],
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ],
          start_pool_metrics?: true
        ]
      }
    )

    refs =
      Enum.map(1..5, fn i ->
        ref =
          Finch.build(:get, "#{url}/wait/500")
          |> Finch.async_request(finch_name)

        send(parent, {:sent_req, i})

        ref
      end)

    Process.sleep(50)

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                in_flight_requests: 5
              }
            ]} = Finch.get_pool_status(finch_name, url)

    Enum.each(refs, fn req_ref ->
      assert_receive {^req_ref, {:status, 200}}, 1000
    end)

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                in_flight_requests: 0
              }
            ]} = Finch.get_pool_status(finch_name, url)
  end

  test "get pool status sync requests", %{test: finch_name, url: url} do
    Finch.TestHelper.start_finch!(
      name: finch_name,
      pools: %{
        url => [
          protocols: [:http2],
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ],
          start_pool_metrics?: true
        ]
      }
    )

    refs =
      Enum.map(1..5, fn _ ->
        Task.async(fn ->
          Finch.build(:get, "#{url}/wait/500")
          |> Finch.request(finch_name)
        end)
      end)

    Process.sleep(50)

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                in_flight_requests: 5
              }
            ]} = Finch.get_pool_status(finch_name, url)

    result = Task.await_many(refs)

    assert length(result) == 5

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                in_flight_requests: 0
              }
            ]} = Finch.get_pool_status(finch_name, url)
  end

  test "multi pool", %{test: finch_name, url: url} do
    parent = self()

    Finch.TestHelper.start_finch!(
      name: finch_name,
      pools: %{
        url => [
          protocols: [:http2],
          conn_opts: [
            transport_opts: [
              verify: :verify_none
            ]
          ],
          count: 2,
          start_pool_metrics?: true
        ]
      }
    )

    refs =
      Enum.map(1..5, fn i ->
        ref =
          Finch.build(:get, "#{url}/wait/500")
          |> Finch.async_request(finch_name)

        send(parent, {:sent_req, i})

        ref
      end)

    Process.sleep(50)

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                in_flight_requests: inflight_1
              },
              %PoolMetrics{
                pool_index: 2,
                in_flight_requests: inflight_2
              }
            ]} = Finch.get_pool_status(finch_name, url)

    assert inflight_1 + inflight_2 == 5

    Enum.each(refs, fn req_ref ->
      assert_receive {^req_ref, {:status, 200}}, 1000
    end)

    assert {:ok,
            [
              %PoolMetrics{
                pool_index: 1,
                in_flight_requests: 0
              },
              %PoolMetrics{
                pool_index: 2,
                in_flight_requests: 0
              }
            ]} = Finch.get_pool_status(finch_name, url)
  end
end
