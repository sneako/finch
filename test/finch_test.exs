defmodule FinchTest do
  use FinchCase, async: true
  doctest Finch

  import ExUnit.CaptureIO

  alias Finch.Response
  alias Finch.MockSocketServer

  describe "start_link/1" do
    test "raises if :name is not provided" do
      assert_raise(ArgumentError, ~r/must supply a name/, fn -> Finch.start_link([]) end)
    end

    test "max_idle_time is deprecated", %{finch_name: finch_name} do
      msg =
        capture_io(:stderr, fn ->
          start_supervised!({Finch, name: finch_name, pools: %{default: [max_idle_time: 1_000]}})
        end)

      assert String.contains?(
               msg,
               ":max_idle_time option is deprecated. Use :conn_max_idle_time instead."
             )
    end

    test "multiple instances can be started under a single supervisor without additional configuration",
         %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      start_supervised!({Finch, name: String.to_atom("#{finch_name}2")})
    end
  end

  describe "pool configuration" do
    test "unconfigured", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)
      assert [_pool] = get_pools(finch_name, shp(bypass))

      {:ok, %Response{}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)
    end

    test "default can be configured", %{bypass: bypass, finch_name: finch_name} do
      {:ok, _} =
        Finch.start_link(
          name: finch_name,
          pools: %{default: [count: 5, size: 5]}
        )

      expect_any(bypass)

      {:ok, %Response{}} = Finch.build("GET", endpoint(bypass)) |> Finch.request(finch_name)
      pools = get_pools(finch_name, shp(bypass))
      assert length(pools) == 5
    end

    test "TLS options will be dropped from default if it connects to http",
         %{bypass: bypass, finch_name: finch_name} do
      {:ok, _} =
        Finch.start_link(
          name: finch_name,
          pools: %{
            default: [
              count: 5,
              size: 5,
              conn_opts: [transport_opts: [verify: :verify_none]]
            ]
          }
        )

      expect_any(bypass)

      # you will get badarg error if the verify option is applied to the connection.
      assert {:ok, %Response{}} =
               Finch.build("GET", endpoint(bypass)) |> Finch.request(finch_name)
    end

    test "raises when invalid configuration is provided", %{finch_name: finch_name} do
      assert_raise(
        NimbleOptions.ValidationError,
        "invalid value for :count option: expected positive integer, got: :dog",
        fn ->
          Finch.start_link(name: finch_name, pools: %{default: [count: :dog]})
        end
      )

      assert_raise(ArgumentError, ~r/invalid destination/, fn ->
        Finch.start_link(name: finch_name, pools: %{invalid: [count: 5, size: 5]})
      end)
    end

    test "pools are started based on only the {scheme, host, port} of the URLs",
         %{bypass: bypass, finch_name: finch_name} do
      other_bypass = Bypass.open()
      default_bypass = Bypass.open()
      unix_socket = {:local, "/my/unix/socket"}

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           endpoint(bypass, "/some-path") => [count: 5, size: 5],
           endpoint(other_bypass, "/some-other-path") => [count: 10, size: 10],
           {:http, unix_socket} => [count: 5, size: 5],
           {:https, unix_socket} => [count: 10, size: 10]
         }}
      )

      assert get_pools(finch_name, shp(bypass)) |> length() == 5
      assert get_pools(finch_name, shp(other_bypass)) |> length() == 10
      assert get_pools(finch_name, shp({:http, unix_socket})) |> length() == 5
      assert get_pools(finch_name, shp({:https, unix_socket})) |> length() == 10

      # no pool has been started for this unconfigured shp
      assert get_pools(finch_name, shp(default_bypass)) |> length() == 0
    end

    test "pools with an invalid URL cannot be started", %{finch_name: finch_name} do
      assert_raise(ArgumentError, ~r/scheme is required for url: example.com/, fn ->
        Finch.start_link(
          name: finch_name,
          pools: %{
            "example.com" => [count: 5, size: 5]
          }
        )
      end)

      assert_raise(ArgumentError, ~r/scheme is required for url: example/, fn ->
        Finch.start_link(
          name: finch_name,
          pools: %{
            "example" => [count: 5, size: 5]
          }
        )
      end)

      assert_raise(ArgumentError, ~r/scheme is required for url: :443/, fn ->
        Finch.start_link(
          name: finch_name,
          pools: %{
            ":443" => [count: 5, size: 5]
          }
        )
      end)
    end

    test "impossible to accidentally start multiple pools when they are dynamically started",
         %{
           bypass: bypass,
           finch_name: finch_name
         } do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [count: 5, size: 5]
         }}
      )

      expect_any(bypass)

      Task.async_stream(
        1..50,
        fn _ -> Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name) end,
        max_concurrency: 50
      )
      |> Stream.run()

      assert get_pools(finch_name, shp(bypass)) |> length() == 5
    end
  end

  describe "build/5" do
    test "raises if unsupported atom request method provided", %{bypass: bypass} do
      assert_raise ArgumentError, ~r/got unsupported atom method :gimme/, fn ->
        Finch.build(:gimme, endpoint(bypass))
      end
    end

    test "raises when requesting a URL with an invalid scheme" do
      assert_raise ArgumentError, ~r"invalid scheme \"ftp\" for url: ftp://example.com", fn ->
        Finch.build(:get, "ftp://example.com")
      end
    end
  end

  describe "request/3" do
    test "successful get request, with query string", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      query_string = "query=value"

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      assert {:ok, %{status: 200}} =
               Finch.build(:get, endpoint(bypass, "?" <> query_string))
               |> Finch.request(finch_name)
    end

    test "successful post request, with body and query string", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!({Finch, name: finch_name})

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
               |> Finch.request(finch_name)

      assert {"content-type", "application/json"} in headers
    end

    test "successful post HTTP/1 streaming request, with streaming body and query string",
         %{
           bypass: bypass,
           finch_name: finch_name
         } do
      start_supervised!({Finch, name: finch_name})

      req_stream = Stream.map(1..10_000, fn _ -> "please" end)
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
               |> Finch.request(finch_name)

      assert {"content-type", "application/json"} in headers
    end

    test "successful post HTTP/2 streaming request, with streaming body and query string",
         %{
           bypass: bypass,
           finch_name: finch_name
         } do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocol: :http2,
             count: 1,
             conn_opts: [
               transport_opts: [
                 verify: :verify_none
               ]
             ]
           ]
         }}
      )

      data = :crypto.strong_rand_bytes(1_000)
      # 1MB of data
      req_stream = Stream.repeatedly(fn -> data end) |> Stream.take(1_000)
      req_body = req_stream |> Enum.join("")
      response_body = data
      header_key = "content-type"
      header_val = "application/octet-stream"
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
               |> Finch.request(finch_name)

      assert {header_key, header_val} in headers
    end

    test "successful post HTTP/2 with a large binary body",
         %{
           bypass: bypass,
           finch_name: finch_name
         } do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocol: :http2,
             count: 1,
             conn_opts: [
               transport_opts: [
                 verify: :verify_none
               ]
             ]
           ]
         }}
      )

      data = :crypto.strong_rand_bytes(1_000)
      # 2MB of data
      req_body = :binary.copy(data, 2_000)
      response_body = data
      header_key = "content-type"
      header_val = "application/octet-stream"
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
               |> Finch.request(finch_name)

      assert {header_key, header_val} in headers
    end

    test "successful post HTTP/2 with a large iolist body",
         %{
           bypass: bypass,
           finch_name: finch_name
         } do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocol: :http2,
             count: 1,
             conn_opts: [
               transport_opts: [
                 verify: :verify_none
               ]
             ]
           ]
         }}
      )

      # 2MB of data
      req_body = List.duplicate(125, 2_000_000)
      req_body_binary = IO.iodata_to_binary(req_body)
      response_body = req_body_binary
      header_key = "content-type"
      header_val = "application/octet-stream"
      query_string = "query=value"

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        assert conn.query_string == query_string
        assert {:ok, ^req_body_binary, conn} = Plug.Conn.read_body(conn)

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
               |> Finch.request(finch_name)

      assert {header_key, header_val} in headers
    end

    test "successful get request, with query string, when given a %URI{}",
         %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      query_string = "query=value"
      uri = URI.parse(endpoint(bypass, "?" <> query_string))

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      assert {:ok, %{status: 200}} = Finch.build(:get, uri) |> Finch.request(finch_name)
    end

    test "successful get request to a unix socket", %{finch_name: finch_name} do
      {:ok, {:local, socket_path}} = MockSocketServer.start()

      start_supervised!({Finch, name: finch_name})

      assert {:ok, %Response{status: 200}} =
               Finch.build(:get, "http://localhost/", [], nil, unix_socket: socket_path)
               |> Finch.request(finch_name)
    end

    @tag :capture_log
    test "successful get request to a unix socket with tls", %{finch_name: finch_name} do
      {:ok, socket_address = {:local, socket_path}} = MockSocketServer.start(ssl?: true)

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           {:https, socket_address} => [conn_opts: [transport_opts: [verify: :verify_none]]]
         }}
      )

      assert {:ok, %Response{status: 200}} =
               Finch.build(:get, "https://localhost/", [], nil, unix_socket: socket_path)
               |> Finch.request(finch_name)
    end

    test "properly handles connection: close", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

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
        assert {:ok, %Response{status: 200, body: "OK"}} = Finch.request(request, finch_name)
      end
    end

    test "returns error when request times out", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      timeout = 100

      Bypass.expect(bypass, fn conn ->
        Process.sleep(timeout + 50)
        Plug.Conn.send_resp(conn, 200, "delayed")
      end)

      assert {:error, %{reason: :timeout}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(finch_name, receive_timeout: timeout)

      assert {:ok, %Response{}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(finch_name, receive_timeout: timeout * 2)
    end

    test "returns error when request times out for chunked response", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!({Finch, name: finch_name})

      timeout = 600

      Bypass.expect(bypass, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(1..5, conn, fn _, conn ->
          Process.sleep(timeout - 100)
          {_, conn} = Plug.Conn.chunk(conn, "chunk-data")
          conn
        end)
      end)

      assert {:error, %{reason: :timeout}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(finch_name, receive_timeout: timeout)

      assert {:ok, %Response{}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(finch_name, receive_timeout: timeout * 10)
    end

    test "returns error when requesting bad address", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      assert {:error, %{reason: :nxdomain}} =
               Finch.build(:get, "http://idontexist.wat") |> Finch.request(finch_name)
    end

    test "worker exits when pool times out", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)

      :sys.suspend(finch_name)

      assert_raise RuntimeError,
                   ~r/Finch was unable to provide a connection within the timeout/,
                   fn ->
                     Finch.build(:get, endpoint(bypass))
                     |> Finch.request(finch_name, pool_timeout: 0)
                   end

      :sys.resume(finch_name)

      assert {:ok, %Response{}} =
               Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name, pool_timeout: 1)
    end
  end

  describe "request!/3" do
    test "returns response on successful request", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      query_string = "query=value"

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert conn.query_string == query_string
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      assert %{status: 200} =
               Finch.build(:get, endpoint(bypass, "?" <> query_string))
               |> Finch.request!(finch_name)
    end

    test "raises exception on bad request", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      assert_raise(Mint.TransportError, fn ->
        Finch.build(:get, "http://idontexist.wat") |> Finch.request!(finch_name)
      end)
    end
  end

  describe "connection options" do
    test "are passed through to the conn", %{bypass: bypass} do
      expect_any(bypass)

      start_supervised!({Finch, name: H1Finch, pools: %{default: [protocol: :http1]}})

      assert {:ok, _} = Finch.build(:get, endpoint(bypass)) |> Finch.request(H1Finch)

      stop_supervised(Finch)
    end

    test "caller is unable to override mode", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch, name: finch_name, pools: %{default: [conn_opts: [mode: :active]]}}
      )

      expect_any(bypass)
      assert {:ok, _} = Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)
    end
  end

  describe "stream/5" do
    test "successful get request, with query string", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
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
               |> Finch.stream(finch_name, acc, fun)
    end

    test "HTTP/1 with atom accumulator, illustrating that the type/shape of the accumulator is not important",
         %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      expect_any(bypass)

      fun = fn _msg, :ok -> :ok end

      assert {:ok, :ok} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.stream(finch_name, :ok, fun)
    end

    test "HTTP/2 with atom accumulator, illustrating that the type/shape of the accumulator is not important",
         %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocol: :http2,
             count: 1,
             conn_opts: [
               transport_opts: [
                 verify: :verify_none
               ]
             ]
           ]
         }}
      )

      expect_any(bypass)

      fun = fn _msg, :ok -> :ok end

      assert {:ok, :ok} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.stream(finch_name, :ok, fun)
    end

    test "successful post request, with query string and string request body",
         %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
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
               |> Finch.stream(finch_name, acc, fun)
    end

    test "successful post request, with query string and streaming request body",
         %{
           bypass: bypass,
           finch_name: finch_name
         } do
      start_supervised!({Finch, name: finch_name})
      query_string = "query=value"
      req_headers = [{"content-type", "application/json"}]
      req_stream = Stream.map(1..10_000, fn _ -> "please" end)
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
               Finch.build(
                 :post,
                 endpoint(bypass, "?" <> query_string),
                 req_headers,
                 {:stream, req_stream}
               )
               |> Finch.stream(finch_name, acc, fun)
    end
  end

  defp get_pools(name, shp) do
    Registry.lookup(name, shp)
  end

  defp shp(%{port: port}), do: {:http, "localhost", port}
  defp shp({scheme, {:local, unix_socket}}), do: {scheme, {:local, unix_socket}, 0}

  defp expect_any(bypass) do
    Bypass.expect(bypass, fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)
  end
end
