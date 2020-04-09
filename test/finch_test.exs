defmodule FinchTest do
  use ExUnit.Case, async: true
  doctest Finch

  alias Finch.Response

  setup do
    {:ok, bypass: Bypass.open()}
  end

  describe "start_link/1" do
    test "raises if :name is not provided" do
      error = assert_raise(ArgumentError, fn -> Finch.start_link([]) end)
      assert error.message =~ "must supply a name"
    end
  end

  describe "pool configuration" do
    test "unconfigured", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass), [], "")
      assert [_pool] = get_pools(MyFinch, shp(bypass))

      {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass), [], "")
    end

    test "default can be configured", %{bypass: bypass} do
      {:ok, _} = Finch.start_link(name: MyFinch, pools: %{default: %{count: 5, size: 5}})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.request(MyFinch, "GET", endpoint(bypass), [], "")
      pools = get_pools(MyFinch, shp(bypass))
      assert length(pools) == 5

      {:ok, %Response{}} = Finch.request(MyFinch, "GET", endpoint(bypass), [], "")
    end

    test "specific scheme, host, port combos can be configurated independently and pools will be started automatically",
         %{bypass: bypass} do
      other_bypass = Bypass.open()
      default_bypass = Bypass.open()

      start_supervised(
        {Finch,
         name: MyFinch,
         pools: %{
           shp(bypass) => %{count: 5, size: 5},
           shp(other_bypass) => %{count: 10, size: 10}
         }}
      )

      assert get_pools(MyFinch, shp(bypass)) |> length() == 5
      assert get_pools(MyFinch, shp(other_bypass)) |> length() == 10

      # no pool has been started for this unconfigured shp
      assert get_pools(MyFinch, shp(default_bypass)) |> length() == 0
    end

    test "impossible to accidentally start multiple pools when they are dynamically started", %{
      bypass: bypass
    } do
      start_supervised(
        {Finch,
         name: MyFinch,
         pools: %{
           default: %{count: 5, size: 5}
         }}
      )

      expect_any(bypass)

      Task.async_stream(1..50, fn _ -> Finch.request(MyFinch, :get, endpoint(bypass)) end,
        max_concurrency: 50
      )
      |> Stream.run()

      assert get_pools(MyFinch, shp(bypass)) |> length() == 5
    end
  end

  describe "request/5" do
    test "successful get request, with query string", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})
      query_string = "query=value"

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      assert {:ok, %{status: 200}} =
               Finch.request(MyFinch, :get, endpoint(bypass, "?" <> query_string))
    end

    test "successful post request, with body and query string", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})

      req_body = "{\"response\":\"please\"}"
      response_body = "{\"right\":\"here\"}"
      header_key = "content-type"
      header_val = "application/json"
      query_string = "query=value"

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        assert conn.query_string == query_string
        assert {:ok, ^req_body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_header(header_key, header_val)
        |> Plug.Conn.send_resp(200, response_body)
      end)

      assert {:ok, %Response{status: 200, headers: headers, body: ^response_body}} =
               Finch.request(
                 MyFinch,
                 :post,
                 endpoint(bypass, "?" <> query_string),
                 [{header_key, header_val}],
                 req_body
               )

      assert {_, "application/json"} =
               Enum.find(headers, fn
                 {"content-type", _} -> true
                 _ -> false
               end)
    end

    test "properly handles connection: close", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("connection", "close")
        |> Plug.Conn.send_resp(200, "OK")
      end)

      assert {:ok, %Response{status: 200, body: "OK"}} =
               Finch.request(
                 MyFinch,
                 :get,
                 endpoint(bypass),
                 [{"connection", "keep-alive"}]
               )
    end

    test "returns error when request times out", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})

      timeout = 100

      Bypass.expect(bypass, fn conn ->
        Process.sleep(timeout + 50)
        Plug.Conn.send_resp(conn, 200, "delayed")
      end)

      assert {:error, %{reason: :timeout}} =
               Finch.request(MyFinch, :get, endpoint(bypass), [], nil, receive_timeout: timeout)

      assert {:ok, %Response{}} =
               Finch.request(MyFinch, :get, endpoint(bypass), [], nil,
                 receive_timeout: timeout * 2
               )
    end

    test "worker exits when pool times out", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})
      expect_any(bypass)

      timeout = 100
      {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass))

      Bypass.down(bypass)

      try do
        Finch.request(MyFinch, :get, endpoint(bypass), [], nil, pool_timeout: timeout)
      catch
        :exit, reason ->
          assert {:timeout, _} = reason
      end

      Bypass.up(bypass)
      assert {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass))
    end
  end

  describe "telemetry" do
    setup %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      client = MyFinch
      start_supervised({Finch, name: client})

      {:ok, client: client}
    end

    test "reports queue spans", %{bypass: bypass, client: client} do
      {test_name, _arity} = __ENV__.function

      parent = self()
      ref = make_ref()

      handler = fn event, measurements, meta, _config ->
        case event do
          [:finch, :queue, :start] ->
            assert is_integer(measurements.system_time)
            assert is_pid(meta.pool)
            send(parent, {ref, :start})

          [:finch, :queue, :stop] ->
            assert is_integer(measurements.duration)
            assert is_pid(meta.pool)
            send(parent, {ref, :stop})

          [:finch, :queue, :exception] ->
            assert is_integer(measurements.duration)
            assert is_pid(meta.pool)
            assert meta.kind == :exit
            assert {:timeout, _} = meta.error
            assert meta.stacktrace != nil
            send(parent, {ref, :exception})

          _ ->
            flunk "Unknown event"
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :queue, :start],
          [:finch, :queue, :stop],
          [:finch, :queue, :exception]
        ],
        handler,
        nil
      )

      assert {:ok, %{status: 200}} = Finch.request(client, :get, endpoint(bypass))
      assert_receive {^ref, :start}
      assert_receive {^ref, :stop}

      Bypass.down(bypass)

      try do
        Finch.request(client, :get, endpoint(bypass), [], nil, pool_timeout: 0)
      catch
        :exit, reason ->
          assert {:timeout, _} = reason
      end

      assert_receive {^ref, :start}
      assert_receive {^ref, :exception}

      :telemetry.detach(to_string(test_name))
    end

    test "reports connection spans", %{bypass: bypass, client: client} do
      {test_name, _arity} = __ENV__.function
      parent = self()
      ref = make_ref()

      handler = fn event, measurements, meta, _config ->
        case event do
          [:finch, :connect, :start] ->
            assert is_integer(measurements.system_time)
            assert is_binary(meta.host)
            send(parent, {ref, :start})

          [:finch, :connect, :stop] ->
            assert is_integer(measurements.duration)
            assert is_binary(meta.host)
            send(parent, {ref, :stop})

          _ ->
            flunk "Unknown event"
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :connect, :start],
          [:finch, :connect, :stop],
        ],
        handler,
        nil
      )

      assert {:ok, %{status: 200}} = Finch.request(client, :get, endpoint(bypass))
      assert_receive {^ref, :start}
      assert_receive {^ref, :stop}

      :telemetry.detach(to_string(test_name))
    end

    test "reports request spans", %{bypass: bypass, client: client} do
      {test_name, _arity} = __ENV__.function

      parent = self()
      ref = make_ref()

      handler = fn event, measurements, meta, _config ->
        case event do
          [:finch, :request, :start] ->
            assert is_integer(measurements.system_time)
            assert is_binary(meta.path)
            send(parent, {ref, :start})

          [:finch, :request, :stop] ->
            assert is_integer(measurements.duration)
            assert is_binary(meta.path)
            send(parent, {ref, :stop})

          _ ->
            flunk "Unknown event"
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :request, :start],
          [:finch, :request, :stop],
          [:finch, :request, :exception]
        ],
        handler,
        nil
      )

      assert {:ok, %{status: 200}} = Finch.request(client, :get, endpoint(bypass))
      assert_receive {^ref, :start}
      assert_receive {^ref, :stop}

      :telemetry.detach(to_string(test_name))
    end

    test "reports response spans", %{bypass: bypass, client: client} do
      {test_name, _arity} = __ENV__.function
      parent = self()
      ref = make_ref()

      handler = fn event, measurements, meta, _config ->
        case event do
          [:finch, :response, :start] ->
            assert is_integer(measurements.system_time)
            assert is_binary(meta.path)
            send(parent, {ref, :start})

          [:finch, :response, :stop] ->
            assert is_integer(measurements.duration)
            assert is_binary(meta.path)
            send(parent, {ref, :stop})

          _ ->
            flunk "Unknown event"
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :response, :start],
          [:finch, :response, :stop],
        ],
        handler,
        nil
      )

      assert {:ok, %{status: 200}} = Finch.request(client, :get, endpoint(bypass))
      assert_receive {^ref, :start}
      assert_receive {^ref, :stop}

      :telemetry.detach(to_string(test_name))
    end
  end


  defp get_pools(name, shp) do
    Registry.lookup(name, shp)
  end

  defp endpoint(%{port: port}, path \\ "/"), do: "http://localhost:#{port}#{path}"

  defp shp(%{port: port}), do: {:http, "localhost", port}

  defp expect_any(bypass) do
    Bypass.expect(bypass, fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)
  end
end
