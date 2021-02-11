defmodule FinchTest do
  use ExUnit.Case, async: true
  doctest Finch

  alias Finch.Response

  setup do
    {:ok, bypass: Bypass.open()}
  end

  describe "start_link/1" do
    test "raises if :name is not provided" do
      assert_raise(ArgumentError, ~r/must supply a name/, fn -> Finch.start_link([]) end)
    end
  end

  describe "pool configuration" do
    test "unconfigured", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(MyFinch)
      assert [_pool] = get_pools(MyFinch, shp(bypass))

      {:ok, %Response{}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(MyFinch)
    end

    test "default can be configured", %{bypass: bypass} do
      {:ok, _} =
        Finch.start_link(
          name: MyFinch,
          pools: %{default: [count: 5, size: 5]}
        )

      expect_any(bypass)

      {:ok, %Response{}} = Finch.build("GET", endpoint(bypass)) |> Finch.request(MyFinch)
      pools = get_pools(MyFinch, shp(bypass))
      assert length(pools) == 5
    end

    test "raises when invalid configuration is provided" do
      assert_raise(
        NimbleOptions.ValidationError,
        ~r/expected :count to be a positive integer/,
        fn ->
          Finch.start_link(name: MyFinch, pools: %{default: [count: :dog]})
        end
      )

      assert_raise(ArgumentError, ~r/invalid destination/, fn ->
        Finch.start_link(name: MyFinch, pools: %{invalid: [count: 5, size: 5]})
      end)
    end

    test "pools are started based on only the {scheme, host, port} of the URLs",
         %{bypass: bypass} do
      other_bypass = Bypass.open()
      default_bypass = Bypass.open()

      start_supervised!(
        {Finch,
         name: MyFinch,
         pools: %{
           endpoint(bypass, "/some-path") => [count: 5, size: 5],
           endpoint(other_bypass, "/some-other-path") => [count: 10, size: 10]
         }}
      )

      assert get_pools(MyFinch, shp(bypass)) |> length() == 5
      assert get_pools(MyFinch, shp(other_bypass)) |> length() == 10

      # no pool has been started for this unconfigured shp
      assert get_pools(MyFinch, shp(default_bypass)) |> length() == 0
    end

    test "pools with an invalid URL cannot be started" do
      assert_raise(ArgumentError, ~r/invalid scheme nil/, fn ->
        Finch.start_link(
          name: MyFinch,
          pools: %{
            "example.com" => [count: 5, size: 5]
          }
        )
      end)

      assert_raise(ArgumentError, ~r/invalid scheme nil/, fn ->
        Finch.start_link(
          name: MyFinch,
          pools: %{
            "example" => [count: 5, size: 5]
          }
        )
      end)

      assert_raise(ArgumentError, ~r/invalid scheme nil/, fn ->
        Finch.start_link(
          name: MyFinch,
          pools: %{
            ":443" => [count: 5, size: 5]
          }
        )
      end)
    end

    test "impossible to accidentally start multiple pools when they are dynamically started", %{
      bypass: bypass
    } do
      start_supervised!(
        {Finch,
         name: MyFinch,
         pools: %{
           default: [count: 5, size: 5]
         }}
      )

      expect_any(bypass)

      Task.async_stream(
        1..50,
        fn _ -> Finch.build(:get, endpoint(bypass)) |> Finch.request(MyFinch) end,
        max_concurrency: 50
      )
      |> Stream.run()

      assert get_pools(MyFinch, shp(bypass)) |> length() == 5
    end
  end

  describe "build/4" do
    test "raises if unsupported atom request method provided", %{bypass: bypass} do
      assert_raise ArgumentError, ~r/got unsupported atom method :gimme/, fn ->
        Finch.build(:gimme, endpoint(bypass))
      end
    end

    test "raises when requesting a URL with an invalid scheme" do
      assert_raise ArgumentError, ~r"invalid scheme \"ftp\"", fn ->
        Finch.build(:get, "ftp://example.com")
      end
    end
  end

  describe "request/3" do
    test "successful get request, with query string", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})
      query_string = "query=value"

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      assert {:ok, %{status: 200}} =
               Finch.build(:get, endpoint(bypass, "?" <> query_string)) |> Finch.request(MyFinch)
    end

    test "successful post request, with body and query string", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})

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
               Finch.build(
                 :post,
                 endpoint(bypass, "?" <> query_string),
                 [{header_key, header_val}],
                 req_body
               )
               |> Finch.request(MyFinch)

      assert {_, "application/json"} =
               Enum.find(headers, fn
                 {"content-type", _} -> true
                 _ -> false
               end)
    end

    test "successful post streaming request, with streaming body and query string", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})

      req_stream = Stream.map(1..10_000, fn(_) -> "please" end)
      req_body = req_stream |> Enum.join("")
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
               Finch.build(
                 :post,
                 endpoint(bypass, "?" <> query_string),
                 [{header_key, header_val}],
                 {:stream, req_stream}
               )
               |> Finch.request(MyFinch)

      assert {_, "application/json"} =
               Enum.find(headers, fn
                 {"content-type", _} -> true
                 _ -> false
               end)
    end

    test "successful get request, with query string, when given a %URI{}", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})
      query_string = "query=value"
      uri = URI.parse(endpoint(bypass, "?" <> query_string))

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      assert {:ok, %{status: 200}} = Finch.build(:get, uri) |> Finch.request(MyFinch)
    end

    test "properly handles connection: close", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("connection", "close")
        |> Plug.Conn.send_resp(200, "OK")
      end)

      request =
        Finch.build(
          :get,
          endpoint(bypass),
          [{"connection", "keep-alive"}]
        )

      for _ <- 1..10 do
        assert {:ok, %Response{status: 200, body: "OK"}} = Finch.request(request, MyFinch)
      end
    end

    test "returns error when request times out", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})

      timeout = 100

      Bypass.expect(bypass, fn conn ->
        Process.sleep(timeout + 50)
        Plug.Conn.send_resp(conn, 200, "delayed")
      end)

      assert {:error, %{reason: :timeout}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(MyFinch, receive_timeout: timeout)

      assert {:ok, %Response{}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(MyFinch, receive_timeout: timeout * 2)
    end

    test "returns error when requesting bad address" do
      start_supervised!({Finch, name: MyFinch})

      assert {:error, %{reason: :nxdomain}} =
               Finch.build(:get, "http://idontexist.wat") |> Finch.request(MyFinch)
    end

    test "worker exits when pool times out", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(MyFinch)

      :sys.suspend(MyFinch)

      assert {:timeout, _} = catch_exit(
        Finch.build(:get, endpoint(bypass)) |> Finch.request(MyFinch, pool_timeout: 0)
      )

      :sys.resume(MyFinch)

      assert {:ok, %Response{}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(MyFinch, pool_timeout: 1)
    end
  end

  describe "connection options" do
    test "are passed through to the conn", %{bypass: bypass} do
      expect_any(bypass)

      start_supervised!({Finch, name: H1Finch, pools: %{default: [protocol: :http1]}})

      assert {:ok, _} = Finch.build(:get, endpoint(bypass)) |> Finch.request(H1Finch)

      stop_supervised(Finch)
    end

    test "caller is unable to override mode", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch, pools: %{default: [conn_opts: [mode: :active]]}})
      expect_any(bypass)
      assert {:ok, _} = Finch.build(:get, endpoint(bypass)) |> Finch.request(MyFinch)
    end
  end

  describe "telemetry" do
    setup %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      client = MyFinch
      start_supervised!({Finch, name: client})

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
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            send(parent, {ref, :start})

          [:finch, :queue, :stop] ->
            assert is_integer(measurements.duration)
            assert is_integer(measurements.idle_time)
            assert is_pid(meta.pool)
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            send(parent, {ref, :stop})

          [:finch, :queue, :exception] ->
            assert is_integer(measurements.duration)
            assert is_pid(meta.pool)
            assert meta.kind == :exit
            assert {:timeout, _} = meta.error
            assert meta.stacktrace != nil
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            send(parent, {ref, :exception})

          _ ->
            flunk("Unknown event")
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

      assert {:ok, %{status: 200}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(client)
      assert_receive {^ref, :start}
      assert_receive {^ref, :stop}

      Bypass.down(bypass)

      try do
        Finch.build(:get, endpoint(bypass)) |> Finch.request(client, pool_timeout: 0)
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
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            send(parent, {ref, :start})

          [:finch, :connect, :stop] ->
            assert is_integer(measurements.duration)
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            send(parent, {ref, :stop})

          _ ->
            flunk("Unknown event")
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :connect, :start],
          [:finch, :connect, :stop]
        ],
        handler,
        nil
      )

      assert {:ok, %{status: 200}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(client)
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
            assert is_integer(measurements.idle_time)
            assert is_binary(meta.path)
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            assert is_binary(meta.method)
            send(parent, {ref, :start})

          [:finch, :request, :stop] ->
            assert is_integer(measurements.duration)
            assert is_integer(measurements.idle_time)
            assert is_binary(meta.path)
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            assert is_binary(meta.method)
            send(parent, {ref, :stop})

          _ ->
            flunk("Unknown event")
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

      assert {:ok, %{status: 200}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(client)
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
            assert is_integer(measurements.idle_time)
            assert is_binary(meta.path)
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            assert is_binary(meta.method)
            send(parent, {ref, :start})

          [:finch, :response, :stop] ->
            assert is_integer(measurements.duration)
            assert is_integer(measurements.idle_time)
            assert is_binary(meta.path)
            assert is_atom(meta.scheme)
            assert is_integer(meta.port)
            assert is_binary(meta.host)
            assert is_binary(meta.method)
            send(parent, {ref, :stop})

          _ ->
            flunk("Unknown event")
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :response, :start],
          [:finch, :response, :stop]
        ],
        handler,
        nil
      )

      assert {:ok, %{status: 200}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(client)
      assert_receive {^ref, :start}
      assert_receive {^ref, :stop}

      :telemetry.detach(to_string(test_name))
    end
  end

  describe "telemetry events which require multiple requests" do
    setup %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      client = MyFinch
      start_supervised!({Finch, name: client, pools: %{default: [max_idle_time: 10]}})

      {:ok, client: client}
    end

    test "reports reused connections", %{bypass: bypass, client: client} do
      {test_name, _arity} = __ENV__.function
      parent = self()
      ref = make_ref()

      handler = fn event, _measurements, meta, _config ->
        case event do
          [:finch, :connect, :start] ->
            send(parent, {ref, :start})

          [:finch, :connect, :stop] ->
            send(parent, {ref, :stop})

          [:finch, :reused_connection] ->
            assert is_atom(meta.scheme)
            assert is_binary(meta.host)
            assert is_integer(meta.port)
            send(parent, {ref, :reused})

          _ ->
            flunk("Unknown event")
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :connect, :start],
          [:finch, :connect, :stop],
          [:finch, :reused_connection]
        ],
        handler,
        nil
      )

      request = Finch.build(:get, endpoint(bypass))
      assert {:ok, %{status: 200}} = Finch.request(request, client)
      assert_receive {^ref, :start}
      assert_receive {^ref, :stop}

      assert {:ok, %{status: 200}} = Finch.request(request, client)
      assert_receive {^ref, :reused}

      :telemetry.detach(to_string(test_name))
    end

    test "reports max_idle_time_exceeded", %{bypass: bypass, client: client} do
      {test_name, _arity} = __ENV__.function
      parent = self()
      ref = make_ref()

      handler = fn event, measurements, meta, _config ->
        case event do
          [:finch, :max_idle_time_exceeded] ->
            assert is_integer(measurements.idle_time)
            assert is_atom(meta.scheme)
            assert is_binary(meta.host)
            assert is_integer(meta.port)
            send(parent, {ref, :max_idle_time_exceeded})

          _ ->
            flunk("Unknown event")
        end
      end

      :telemetry.attach_many(
        to_string(test_name),
        [
          [:finch, :max_idle_time_exceeded]
        ],
        handler,
        nil
      )

      request = Finch.build(:get, endpoint(bypass))
      assert {:ok, %{status: 200}} = Finch.request(request, client)
      Process.sleep(15)
      assert {:ok, %{status: 200}} = Finch.request(request, client)
      assert_receive {^ref, :max_idle_time_exceeded}

      :telemetry.detach(to_string(test_name))
    end
  end

  describe "stream/5" do
    test "successful get request, with query string", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})
      query_string = "query=value"

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {value, headers, body}
        {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, value}, {status, headers, body} -> {status, headers, body <> value}
      end

      assert {:ok, {200, [_ | _], "OK"}} =
               Finch.build(:get, endpoint(bypass, "?" <> query_string))
               |> Finch.stream(MyFinch, acc, fun)
    end

    test "successful post request, with query string and string request body", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})
      query_string = "query=value"
      req_headers = [{"content-type", "application/json"}]
      req_body = "{hello:\"world\"}"
      resp_body = "{hi:\"there\"}"

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, resp_body)
      end)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {value, headers, body}
        {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, value}, {status, headers, body} -> {status, headers, body <> value}
      end

      assert {:ok, {200, [_ | _], ^resp_body}} =
               Finch.build(:post, endpoint(bypass, "?" <> query_string), req_headers, req_body)
               |> Finch.stream(MyFinch, acc, fun)
    end

    test "successful post request, with query string and streaming request body", %{bypass: bypass} do
      start_supervised!({Finch, name: MyFinch})
      query_string = "query=value"
      req_headers = [{"content-type", "application/json"}]
      req_stream = Stream.map(1..10_000, fn(_) -> "please" end)
      resp_body = "{hi:\"there\"}"

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, resp_body)
      end)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {value, headers, body}
        {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, value}, {status, headers, body} -> {status, headers, body <> value}
      end

      assert {:ok, {200, [_ | _], ^resp_body}} =
               Finch.build(:post, endpoint(bypass, "?" <> query_string), req_headers, {:stream, req_stream})
               |> Finch.stream(MyFinch, acc, fun)
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
