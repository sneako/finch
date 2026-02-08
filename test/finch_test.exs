defmodule FinchTest do
  use FinchCase, async: true

  alias Finch.Response
  alias Finch.MockSocketServer

  describe "start_link/1" do
    test "raises if :name is not provided" do
      assert_raise(ArgumentError, ~r/must supply a name/, fn -> Finch.start_link([]) end)
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
      assert [_pool] = get_pools(finch_name, pool(bypass))

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
      pools = get_pools(finch_name, pool(bypass))
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
      unix_socket_path = "/my/unix/socket"
      http_unix_pool = Finch.Pool.new("http+unix://#{unix_socket_path}")
      https_unix_pool = Finch.Pool.new("https+unix://#{unix_socket_path}")

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           endpoint(bypass, "/some-path") => [count: 5, size: 5],
           endpoint(other_bypass, "/some-other-path") => [count: 10, size: 10],
           http_unix_pool => [count: 5, size: 5],
           https_unix_pool => [count: 10, size: 10]
         }}
      )

      assert get_pools(finch_name, pool(bypass)) |> length() == 5
      assert get_pools(finch_name, pool(other_bypass)) |> length() == 10
      assert get_pools(finch_name, http_unix_pool) |> length() == 5
      assert get_pools(finch_name, https_unix_pool) |> length() == 10

      # no pool has been started for this unconfigured shp
      assert get_pools(finch_name, pool(default_bypass)) |> length() == 0
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

      assert get_pools(finch_name, pool(bypass)) |> length() == 5
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
             protocols: [:http2],
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
             protocols: [:http2],
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
             protocols: [:http2],
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

    @tag :tmp_dir
    test "successful get request to a unix socket", %{finch_name: finch_name, tmp_dir: tmp_dir} do
      # erlang doesn't like long socket paths, we can trick it by using a shorter relative path.
      socket_path = Path.relative_to_cwd("#{tmp_dir}/finch.sock")
      {:ok, _} = MockSocketServer.start(address: {:local, socket_path})

      start_supervised!({Finch, name: finch_name})

      assert {:ok, %Response{status: 200}} =
               Finch.build(:get, "http://localhost/", [], nil, unix_socket: socket_path)
               |> Finch.request(finch_name)
    end

    @tag :capture_log
    test "successful get request to a unix socket with tls", %{finch_name: finch_name} do
      # Use short absolute path (Unix socket path length limit)
      socket_path = "/tmp/finch-tls-#{System.unique_integer([:positive])}.sock"
      {:ok, _} = MockSocketServer.start(address: {:local, socket_path}, transport: :ssl)

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new("https+unix://#{socket_path}") => [
             conn_opts: [transport_opts: [verify: :verify_none]]
           ]
         }}
      )

      assert {:ok, %Response{status: 200}} =
               Finch.build(:get, "https://localhost/", [], nil, unix_socket: socket_path)
               |> Finch.request(finch_name)
    end

    @tag :tmp_dir
    test "Finch.Pool.new/1 parses http+unix:// URLs", %{tmp_dir: tmp_dir} do
      socket_path = Path.expand("#{tmp_dir}/api.sock")
      pool = Finch.Pool.new("http+unix://#{socket_path}")

      assert pool == %Finch.Pool{
               scheme: :http,
               host: {:local, socket_path},
               port: 0,
               tag: :default
             }
    end

    @tag :tmp_dir
    test "Finch.Pool.new/1 parses https+unix:// URLs", %{tmp_dir: tmp_dir} do
      socket_path = Path.expand("#{tmp_dir}/api.sock")
      pool = Finch.Pool.new("https+unix://#{socket_path}")

      assert pool.scheme == :https
      assert pool.host == {:local, socket_path}
      assert pool.port == 0
      assert pool.tag == :default
    end

    test "pool configuration with http+unix:// URL", %{test: test} do
      # Use short path as some unix systems have path limit
      socket_path = "/tmp/finch-url-#{System.unique_integer([:positive])}.sock"
      {:ok, _} = MockSocketServer.start(address: {:local, socket_path})

      start_supervised!({
        Finch,
        name: test,
        pools: %{
          Finch.Pool.new("http+unix://#{socket_path}") => [count: 1, size: 1]
        }
      })

      req =
        Finch.build(:get, "http://localhost/", [], nil, unix_socket: socket_path)

      assert {:ok, %{status: 200}} = Finch.request(req, test)
    end

    @tag :tmp_dir
    test "tagged pool with http+unix:// URL", %{tmp_dir: tmp_dir} do
      socket_path = Path.expand("#{tmp_dir}/finch.sock")
      pool = Finch.Pool.new("http+unix://#{socket_path}", tag: :api)

      assert pool.tag == :api
      assert pool.host == {:local, socket_path}
    end

    @tag :tmp_dir
    test "tagged pool with https+unix:// URL", %{tmp_dir: tmp_dir} do
      socket_path = Path.expand("#{tmp_dir}/finch.sock")
      pool = Finch.Pool.new("https+unix://#{socket_path}", tag: :secure)

      assert pool.scheme == :https
      assert pool.tag == :secure
      assert pool.host == {:local, socket_path}
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
        Process.flag(:trap_exit, true)
        Process.sleep(timeout + 50)

        receive do
          {:EXIT, _, _} -> {:halt, conn}
        after
          0 ->
            Plug.Conn.send_resp(conn, 200, "delayed")
        end
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
        Process.flag(:trap_exit, true)
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce_while(1..5, conn, fn _, conn ->
          Process.sleep(timeout - 100)

          receive do
            {:EXIT, _, _} -> {:halt, conn}
          after
            0 ->
              {_, conn} = Plug.Conn.chunk(conn, "chunk-data")
              {:cont, conn}
          end
        end)
      end)

      assert {:error, %{reason: :timeout}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(finch_name, request_timeout: timeout)

      assert {:ok, %Response{}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.request(finch_name, request_timeout: timeout * 10)
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

      start_supervised!({Finch, name: H1Finch, pools: %{default: [protocols: [:http1]]}})

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

    test "unsuccessful get request", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {value, headers, body}
        {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, value}, {status, headers, body} -> {status, headers, body <> value}
      end

      assert {:error, %{reason: :nxdomain}, ^acc} =
               Finch.build(:get, "http://idontexist.wat") |> Finch.stream(finch_name, acc, fun)
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
             protocols: [:http2],
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

  describe "stream_while/5" do
    test "successful get request with HTTP/1", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert Plug.Conn.get_http_protocol(conn) == :"HTTP/1.1"
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:cont, {status, headers ++ value, body}}
        {:data, value}, {status, headers, body} -> {:cont, {status, headers, body <> value}}
      end

      assert {:ok, {200, [_ | _], "OK"}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.stream_while(finch_name, acc, fun)
    end

    test "unsuccessful get request", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:cont, {status, headers ++ value, body}}
        {:data, value}, {status, headers, body} -> {:cont, {status, headers, body <> value}}
      end

      assert {:error, %{reason: :nxdomain}, ^acc} =
               Finch.build(:get, "http://idontexist.wat")
               |> Finch.stream_while(finch_name, acc, fun)
    end

    defmodule InfiniteStream do
      def init(options), do: options

      def call(conn, []) do
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(Stream.cycle(["chunk"]), conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          Process.sleep(10)
          conn
        end)
      end
    end

    test "function halts on HTTP/1", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      # Start custom server because Bypass would complain when it outlives test process.
      url = start_server(plug: InfiniteStream)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {:halt, {value, headers, body}}
      end

      assert {:ok, {200, [], ""}} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:halt, {status, headers ++ value, body}}
      end

      assert {:ok, {200, [_ | _], ""}} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:cont, {status, headers ++ value, body}}
        {:data, value}, {status, headers, body} -> {:halt, {status, headers, body <> value}}
      end

      assert {:ok, {200, [_ | _], "chunk"}} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)
    end

    test "invalid return value on HTTP/1", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      Bypass.stub(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      acc = {nil, [], ""}

      fun = fn
        {:status, _value}, _acc -> :bad
      end

      assert_raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: :bad", fn ->
        Finch.build(:get, endpoint(bypass))
        |> Finch.stream_while(finch_name, acc, fun)
      end
    end

    test "successful get request with HTTP/2", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocols: [:http2]
           ]
         }}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:cont, {status, headers ++ value, body}}
        {:data, value}, {status, headers, body} -> {:cont, {status, headers, body <> value}}
      end

      assert {:ok, {200, [_ | _], "OK"}} =
               Finch.build(:get, endpoint(bypass))
               |> Finch.stream_while(finch_name, acc, fun)
    end

    test "function halts on HTTP/2", %{finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocols: [:http2]
           ]
         }}
      )

      # Start custom server because Bypass would complain when it outlives test process.
      url =
        start_server(
          plug: [
            fn conn ->
              assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
              conn
            end,
            {InfiniteStream, []}
          ]
        )

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {:halt, {value, headers, body}}
      end

      assert {:ok, {200, [], ""}} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:halt, {status, headers ++ value, body}}
      end

      assert {:ok, {200, [_ | _], ""}} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:cont, {status, headers ++ value, body}}
        {:data, value}, {status, headers, body} -> {:halt, {status, headers, body <> value}}
      end

      assert {:ok, {200, [_ | _], "chunk"}} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)

      Process.sleep(1000)
    end

    test "invalid return value on HTTP/2", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocols: [:http2]
           ]
         }}
      )

      Bypass.stub(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      acc = {nil, [], ""}

      fun = fn
        {:status, _value}, _acc -> :bad
      end

      assert_raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: :bad", fn ->
        Finch.build(:get, endpoint(bypass))
        |> Finch.stream_while(finch_name, acc, fun)
      end
    end

    test "successful get request with HTTP/1 + HTTP/2", %{finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocols: [:http1, :http2],
             conn_opts: [transport_opts: [verify: :verify_none]]
           ]
         }}
      )

      # Start custom server because Bypass does not support HTTP/1.1 + HTTP/2 (ALPN)
      url =
        start_server(
          plug: fn conn ->
            assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
            Plug.Conn.send_resp(conn, 200, "OK")
          end,
          scheme: :https
        )

      acc = []
      fun = fn {name, value}, acc -> {:cont, acc ++ [{name, value}]} end

      assert {:ok, [status: 200, headers: _, data: "OK"]} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)
    end

    test "function halts on HTTP/1 + HTTP/2", %{finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocols: [:http1, :http2],
             conn_opts: [transport_opts: [verify: :verify_none]]
           ]
         }}
      )

      # Start custom server because Bypass does not support HTTP/1.1 + HTTP/2 (ALPN)
      url =
        start_server(
          plug: [
            fn conn ->
              assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
              conn
            end,
            {InfiniteStream, []}
          ],
          scheme: :https
        )

      acc = []

      fun = fn
        {:status, value}, acc -> {:cont, acc ++ [{:status, value}]}
        {:headers, value}, acc -> {:halt, acc ++ [{:headers, value}]}
      end

      assert {:ok, [status: 200, headers: _]} =
               Finch.build(:get, url)
               |> Finch.stream_while(finch_name, acc, fun)
    end
  end

  describe "is_request_ref/1" do
    test "guard matches valid request ref from async_request", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      require Finch
      start_supervised!({Finch, name: finch_name})

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      request_ref =
        Finch.build(:get, endpoint(bypass))
        |> Finch.async_request(finch_name)

      # Consume async response so Bypass expectation is satisfied
      assert_receive {^request_ref, {:status, 200}}
      assert_receive {^request_ref, {:headers, _}}
      assert_receive {^request_ref, {:data, "OK"}}
      assert_receive {^request_ref, :done}

      # Test that the guard matches this ref in a handle_info-style receive
      parent = self()

      pid =
        spawn(fn ->
          receive do
            {ref, _} when Finch.is_request_ref(ref) -> send(parent, :matched)
            _ -> send(parent, :unmatched)
          end
        end)

      send(pid, {request_ref, :done})
      assert_receive :matched
    end

    test "guard does not match invalid values" do
      require Finch

      parent = self()

      pid =
        spawn(fn ->
          receive do
            {ref, _} when Finch.is_request_ref(ref) -> send(parent, :matched)
            _ -> send(parent, :unmatched)
          end
        end)

      send(pid, {:not_a_ref, :done})
      assert_receive :unmatched
    end
  end

  describe "async_request/3 with HTTP/1" do
    test "sends response messages to calling process", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      request_ref =
        Finch.build(:get, endpoint(bypass))
        |> Finch.async_request(finch_name)

      assert_receive {^request_ref, {:status, 200}}
      assert_receive {^request_ref, {:headers, headers}} when is_list(headers)
      assert_receive {^request_ref, {:data, "OK"}}
      assert_receive {^request_ref, :done}
    end

    test "sends chunked response messages to calling process", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!({Finch, name: finch_name})

      Bypass.expect(bypass, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(1..5, conn, fn _, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk-data")
          conn
        end)
      end)

      request_ref =
        Finch.build(:get, endpoint(bypass))
        |> Finch.async_request(finch_name)

      assert_receive {^request_ref, {:status, 200}}
      assert_receive {^request_ref, {:headers, headers}} when is_list(headers)
      for _ <- 1..5, do: assert_receive({^request_ref, {:data, "chunk-data"}})
      assert_receive {^request_ref, :done}
    end
  end

  describe "pool_tag functionality" do
    test "pool_tag option in build/5 defaults to :default", %{bypass: bypass} do
      request = Finch.build(:get, endpoint(bypass))
      assert request.pool_tag == :default
    end

    test "pool_tag option in build/5 can be set", %{bypass: bypass} do
      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :api)
      assert request.pool_tag == :api
    end

    test "tagged pools are configured with Finch.Pool.new/2", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :api) => [count: 3, size: 3],
           Finch.Pool.new(endpoint(bypass), tag: :web) => [count: 5, size: 5]
         }}
      )

      expect_any(bypass)

      # Make requests to trigger pool creation
      api_request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :api)
      web_request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :web)

      {:ok, %Response{}} = Finch.request(api_request, finch_name)
      {:ok, %Response{}} = Finch.request(web_request, finch_name)

      api_pool = Finch.Pool.new(endpoint(bypass), tag: :api)
      web_pool = Finch.Pool.new(endpoint(bypass), tag: :web)

      assert get_pools(finch_name, api_pool) |> length() == 3
      assert get_pools(finch_name, web_pool) |> length() == 5
    end

    test "pool config fallback: exact match -> default config", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :api) => [count: 3, size: 3],
           endpoint(bypass) => [count: 5, size: 5],
           default: [count: 7, size: 7]
         }}
      )

      expect_any(bypass)

      # Exact match for :api tag
      api_request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :api)
      {:ok, %Response{}} = Finch.request(api_request, finch_name)
      api_pool = Finch.Pool.new(endpoint(bypass), tag: :api)
      assert get_pools(finch_name, api_pool) |> length() == 3

      # When a specific pool_tag doesn't exist, use default config (don't fall back to :default tag)
      other_request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :other)
      {:ok, %Response{}} = Finch.request(other_request, finch_name)
      other_pool = Finch.Pool.new(endpoint(bypass), tag: :other)
      assert get_pools(finch_name, other_pool) |> length() == 7

      # Falls back to default config for unconfigured host
      other_bypass = Bypass.open()

      Bypass.expect_once(other_bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      unconfigured_request = Finch.build(:get, endpoint(other_bypass), [], nil, pool_tag: :api)
      {:ok, %Response{}} = Finch.request(unconfigured_request, finch_name)
      unconfigured_pool = Finch.Pool.new(endpoint(other_bypass), tag: :api)
      assert get_pools(finch_name, unconfigured_pool) |> length() == 7
    end

    test "get_pool_status/2 with Finch.Pool struct", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :api) => [
             start_pool_metrics?: true,
             count: 2
           ]
         }}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)

      url = endpoint(bypass)
      request = Finch.build(:get, url, [], nil, pool_tag: :api)
      {:ok, %{status: 200}} = Finch.request(request, finch_name)

      api_pool = Finch.Pool.new(url, tag: :api)
      web_pool = Finch.Pool.new(url, tag: :web)
      assert {:ok, _metrics} = Finch.get_pool_status(finch_name, api_pool)
      assert {:error, :not_found} = Finch.get_pool_status(finch_name, web_pool)
    end

    test "stop_pool/2 with Finch.Pool struct", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :api) => [count: 2],
           Finch.Pool.new(endpoint(bypass), tag: :web) => [count: 2]
         }}
      )

      Bypass.expect(bypass, fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)

      url = endpoint(bypass)

      api_request = Finch.build(:get, url, [], nil, pool_tag: :api)
      web_request = Finch.build(:get, url, [], nil, pool_tag: :web)

      {:ok, %{status: 200}} = Finch.request(api_request, finch_name)
      {:ok, %{status: 200}} = Finch.request(web_request, finch_name)

      api_pool = Finch.Pool.new(url, tag: :api)
      web_pool = Finch.Pool.new(url, tag: :web)

      assert Finch.stop_pool(finch_name, api_pool) == :ok
      assert pool_stopped?(finch_name, api_pool)

      # Web pool should still exist
      assert get_pools(finch_name, web_pool) |> length() == 2

      assert Finch.stop_pool(finch_name, web_pool) == :ok
      assert pool_stopped?(finch_name, web_pool)
    end

    @tag :tmp_dir
    test "pool_tag works with unix sockets", %{finch_name: finch_name, tmp_dir: tmp_dir} do
      socket_path = Path.relative_to_cwd("#{tmp_dir}/finch.sock")
      {:ok, _} = MockSocketServer.start(address: {:local, socket_path})

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new("http://localhost/", tag: :api) => [count: 2]
         }}
      )

      request =
        Finch.build(:get, "http://localhost/", [], nil,
          unix_socket: socket_path,
          pool_tag: :api
        )

      assert {:ok, %Response{status: 200}} = Finch.request(request, finch_name)
    end

    @tag :tmp_dir
    test "tagged Unix socket pools can be configured", %{finch_name: finch_name, tmp_dir: tmp_dir} do
      api_socket_path = Path.relative_to_cwd("#{tmp_dir}/api.sock")
      web_socket_path = Path.relative_to_cwd("#{tmp_dir}/web.sock")

      {:ok, _} = MockSocketServer.start(address: {:local, api_socket_path})
      {:ok, _} = MockSocketServer.start(address: {:local, web_socket_path})

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new("http+unix://#{api_socket_path}", tag: :api) => [count: 3, size: 3],
           Finch.Pool.new("http+unix://#{web_socket_path}", tag: :web) => [count: 5, size: 5]
         }}
      )

      # Make requests to trigger pool creation
      api_request =
        Finch.build(:get, "http://localhost/", [], nil,
          unix_socket: api_socket_path,
          pool_tag: :api
        )

      web_request =
        Finch.build(:get, "http://localhost/", [], nil,
          unix_socket: web_socket_path,
          pool_tag: :web
        )

      {:ok, %Response{status: 200}} = Finch.request(api_request, finch_name)
      {:ok, %Response{status: 200}} = Finch.request(web_request, finch_name)

      api_pool = Finch.Pool.new("http+unix://#{api_socket_path}", tag: :api)
      web_pool = Finch.Pool.new("http+unix://#{web_socket_path}", tag: :web)

      assert get_pools(finch_name, api_pool) |> length() == 3
      assert get_pools(finch_name, web_pool) |> length() == 5
    end

    @tag :tmp_dir
    test "get_pool_status/2 with tagged Unix socket", %{finch_name: finch_name, tmp_dir: tmp_dir} do
      socket_path = Path.relative_to_cwd("#{tmp_dir}/finch.sock")
      {:ok, _} = MockSocketServer.start(address: {:local, socket_path})

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new("http+unix://#{socket_path}", tag: :api) => [
             start_pool_metrics?: true,
             count: 2
           ]
         }}
      )

      request =
        Finch.build(:get, "http://localhost/", [], nil,
          unix_socket: socket_path,
          pool_tag: :api
        )

      {:ok, %{status: 200}} = Finch.request(request, finch_name)

      api_pool = Finch.Pool.new("http+unix://#{socket_path}", tag: :api)
      web_pool = Finch.Pool.new("http+unix://#{socket_path}", tag: :web)

      assert {:ok, _metrics} = Finch.get_pool_status(finch_name, api_pool)
      assert {:error, :not_found} = Finch.get_pool_status(finch_name, web_pool)
    end

    @tag :tmp_dir
    test "stop_pool/2 with tagged Unix socket", %{finch_name: finch_name, tmp_dir: tmp_dir} do
      api_socket_path = Path.relative_to_cwd("#{tmp_dir}/api.sock")
      web_socket_path = Path.relative_to_cwd("#{tmp_dir}/web.sock")
      default_socket_path = Path.relative_to_cwd("#{tmp_dir}/default.sock")

      {:ok, _} = MockSocketServer.start(address: {:local, api_socket_path})
      {:ok, _} = MockSocketServer.start(address: {:local, web_socket_path})
      {:ok, _} = MockSocketServer.start(address: {:local, default_socket_path})

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new("http+unix://#{api_socket_path}", tag: :api) => [count: 2],
           Finch.Pool.new("http+unix://#{web_socket_path}", tag: :web) => [count: 2],
           Finch.Pool.new("http+unix://#{default_socket_path}") => [count: 2]
         }}
      )

      api_request =
        Finch.build(:get, "http://localhost/", [], nil,
          unix_socket: api_socket_path,
          pool_tag: :api
        )

      web_request =
        Finch.build(:get, "http://localhost/", [], nil,
          unix_socket: web_socket_path,
          pool_tag: :web
        )

      default_tag_request =
        Finch.build(:get, "http://localhost/", [], nil, unix_socket: default_socket_path)

      assert {:ok, %{status: 200}} = Finch.request(api_request, finch_name)
      assert {:ok, %{status: 200}} = Finch.request(web_request, finch_name)
      assert {:ok, %{status: 200}} = Finch.request(default_tag_request, finch_name)

      api_pool = Finch.Pool.new("http+unix://#{api_socket_path}", tag: :api)
      web_pool = Finch.Pool.new("http+unix://#{web_socket_path}", tag: :web)

      assert Finch.stop_pool(finch_name, api_pool) == :ok
      assert pool_stopped?(finch_name, api_pool)

      # web pool should still exist
      assert get_pools(finch_name, web_pool) |> length() == 2

      assert Finch.stop_pool(finch_name, web_pool) == :ok
      assert pool_stopped?(finch_name, web_pool)

      # default tag pool should still exist
      default_pool = Finch.Pool.new("http+unix://#{default_socket_path}")
      assert get_pools(finch_name, default_pool) |> length() == 2

      assert Finch.stop_pool(finch_name, default_pool) == :ok
      assert pool_stopped?(finch_name, default_pool)
    end

    test "default pool_tag is used when not specified", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :default) => [count: 3, size: 3]
         }}
      )

      expect_any(bypass)

      # Request without pool_tag should use :default
      request = Finch.build(:get, endpoint(bypass))
      {:ok, %Response{}} = Finch.request(request, finch_name)

      default_pool = Finch.Pool.new(endpoint(bypass), tag: :default)
      assert get_pools(finch_name, default_pool) |> length() == 3
    end

    test "async_request/3 with pool_tag", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :api) => [count: 1]
         }}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :api)
      request_ref = Finch.async_request(request, finch_name)

      assert_receive {^request_ref, {:status, 200}}
      assert_receive {^request_ref, {:headers, _headers}}
      assert_receive {^request_ref, {:data, "OK"}}
      assert_receive {^request_ref, :done}
    end

    test "stream/5 with pool_tag", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :api) => [count: 1]
         }}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :api)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {value, headers, body}
        {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, value}, {status, headers, body} -> {status, headers, body <> value}
      end

      assert {:ok, {200, _headers, "OK"}} = Finch.stream(request, finch_name, acc, fun)
    end

    test "stream_while/5 with pool_tag", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           Finch.Pool.new(endpoint(bypass), tag: :api) => [count: 1]
         }}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :api)

      acc = {nil, [], ""}

      fun = fn
        {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
        {:headers, value}, {status, headers, body} -> {:cont, {status, headers ++ value, body}}
        {:data, value}, {status, headers, body} -> {:cont, {status, headers, body <> value}}
      end

      assert {:ok, {200, _headers, "OK"}} = Finch.stream_while(request, finch_name, acc, fun)
    end
  end

  describe "find_pool/2" do
    test "returns {:ok, pid} for existing pools", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      expect_any(bypass)

      _ = Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)

      pool = Finch.Pool.new(endpoint(bypass))
      assert {:ok, pid} = Finch.find_pool(finch_name, pool)
      assert is_pid(pid)
    end

    test "returns :error for non-existent pools", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      pool = Finch.Pool.new("http://nonexistent.example.com", tag: :api)
      assert Finch.find_pool(finch_name, pool) == :error
    end
  end

  describe "dynamic pool creation" do
    test "start_pool/3 starts a pool under Finch's tree", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!({Finch, name: finch_name})
      expect_any(bypass)

      :ok =
        Finch.start_pool(
          finch_name,
          Finch.Pool.new(endpoint(bypass), tag: :hello),
          size: 30,
          count: 2
        )

      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :hello)
      {:ok, %Response{}} = Finch.request(request, finch_name)

      pool = Finch.Pool.new(endpoint(bypass), tag: :hello)
      assert get_pools(finch_name, pool) |> length() == 2
    end

    test "dynamic pool creation with start_link/1", %{bypass: bypass, finch_name: finch_name} do
      # Start Finch without the pool configured
      start_supervised!({Finch, name: finch_name})

      expect_any(bypass)

      # Dynamically start a tagged pool
      :ok =
        Finch.start_pool(
          finch_name,
          Finch.Pool.new(endpoint(bypass), tag: :hello),
          size: 30,
          count: 2
        )

      # Make a request using the dynamically created pool
      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :hello)
      {:ok, %Response{}} = Finch.request(request, finch_name)

      # Verify the pool was created with the correct configuration
      pool = Finch.Pool.new(endpoint(bypass), tag: :hello)
      assert get_pools(finch_name, pool) |> length() == 2
    end

    test "dynamic pool creation without tag uses default", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!({Finch, name: finch_name})

      expect_any(bypass)

      # Dynamically start a pool without a tag (uses :default)
      :ok =
        Finch.start_pool(
          finch_name,
          Finch.Pool.new(endpoint(bypass)),
          size: 50,
          count: 1
        )

      # Make a request without specifying pool_tag (uses :default)
      request = Finch.build(:get, endpoint(bypass))
      {:ok, %Response{}} = Finch.request(request, finch_name)

      # Verify the pool was created
      pool = Finch.Pool.new(endpoint(bypass))
      assert get_pools(finch_name, pool) |> length() == 1
    end

    test "dynamic pool creation validates options", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      assert_raise ArgumentError, fn ->
        Finch.start_pool(
          finch_name,
          Finch.Pool.new("http://example.com"),
          invalid_option: :value
        )
      end
    end
  end

  describe "user-managed pools (Finch.Pool.child_spec/1)" do
    test "{Finch.Pool, ...} can be added to a supervision tree", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      # Finch must be started first so the registry exists when building the pool child_spec
      start_supervised!({Finch, name: finch_name})

      start_supervised!(
        {Finch.Pool,
         finch: finch_name,
         pool: Finch.Pool.new(endpoint(bypass), tag: :usermanaged),
         size: 5,
         count: 2}
      )

      pool = Finch.Pool.new(endpoint(bypass), tag: :usermanaged)
      assert {:ok, _pid} = Finch.find_pool(finch_name, pool)
      assert get_pools(finch_name, pool) |> length() == 2
    end

    test "user-managed pool can be used for requests", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      start_supervised!(
        {Finch.Pool,
         finch: finch_name, pool: Finch.Pool.new(endpoint(bypass), tag: :usermanaged), size: 5}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :usermanaged)
      assert {:ok, %Response{status: 200, body: "OK"}} = Finch.request(request, finch_name)
    end

    test "stop_pool/2 works on user-managed pools", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})

      start_supervised!(
        {Finch.Pool,
         finch: finch_name, pool: Finch.Pool.new(endpoint(bypass), tag: :usermanaged), size: 5}
      )

      expect_any(bypass)

      pool = Finch.Pool.new(endpoint(bypass), tag: :usermanaged)

      _ =
        Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :usermanaged)
        |> Finch.request(finch_name)

      assert Finch.stop_pool(finch_name, pool) == :ok

      assert eventually(
               fn -> Finch.find_pool(finch_name, pool) == :error end,
               100,
               50
             )
    end

    test "get_pool_status/2 works with user-managed pool when metrics enabled", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!({Finch, name: finch_name})

      start_supervised!(
        {Finch.Pool,
         finch: finch_name,
         pool: Finch.Pool.new(endpoint(bypass), tag: :usermanaged),
         size: 5,
         start_pool_metrics?: true}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "OK")
      end)

      request = Finch.build(:get, endpoint(bypass), [], nil, pool_tag: :usermanaged)
      {:ok, _} = Finch.request(request, finch_name)

      pool = Finch.Pool.new(endpoint(bypass), tag: :usermanaged)
      assert {:ok, _metrics} = Finch.get_pool_status(finch_name, pool)
    end

    test "pool workers are cleaned up from registry when supervisor terminates", %{
      bypass: bypass,
      finch_name: finch_name
    } do
      start_supervised!({Finch, name: finch_name})

      start_supervised(
        {Finch.Pool,
         finch: finch_name, pool: Finch.Pool.new(endpoint(bypass), tag: :usermanaged), size: 2}
      )

      pool = Finch.Pool.new(endpoint(bypass), tag: :usermanaged)
      assert {:ok, _pid} = Finch.find_pool(finch_name, pool)

      # Stop the pool by stopping the pool supervisor (id is from child_spec)
      pool_name = Finch.Pool.to_name(pool)
      stop_supervised({Finch.Pool.Supervisor, pool_name})

      assert eventually(
               fn -> Finch.find_pool(finch_name, pool) == :error end,
               100,
               50
             )
    end
  end

  describe "get_pool_status/2" do
    test "fails if the pool doesn't exist", %{finch_name: finch_name} do
      start_supervised!({Finch, name: finch_name})
      assert Finch.stop_pool(finch_name, "http://unknown.url/") == {:error, :not_found}
    end

    test "succeeds with a string url", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch, name: finch_name, pools: %{default: [start_pool_metrics?: true, count: 2]}}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)

      url = endpoint(bypass)
      {:ok, %{status: 200}} = Finch.build(:get, url) |> Finch.request(finch_name)

      assert Finch.stop_pool(finch_name, url) == :ok

      assert pool_stopped?(finch_name, url)
    end

    test "succeeds with an shp tuple", %{bypass: bypass, finch_name: finch_name} do
      start_supervised!(
        {Finch, name: finch_name, pools: %{default: [start_pool_metrics?: true, count: 2]}}
      )

      Bypass.expect_once(bypass, "GET", "/", fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)

      url = endpoint(bypass)
      {:ok, %{status: 200}} = Finch.build(:get, url) |> Finch.request(finch_name)

      {s, h, p, _, _} = Finch.Request.parse_url(url)

      assert Finch.stop_pool(finch_name, {s, h, p}) == :ok
      assert pool_stopped?(finch_name, {s, h, p})
    end

    defp pool_stopped?(finch_name, url) do
      # Need to use this pattern because the pools may linger on for a short while in the registry.
      eventually(
        fn -> Finch.get_pool_status(finch_name, url) == {:error, :not_found} end,
        100,
        50
      )
    end

    defp eventually(fun, _backoff, 0), do: fun.()

    defp eventually(fun, backoff, retries) do
      if fun.() do
        true
      else
        Process.sleep(backoff)
        eventually(fun, backoff, retries - 1)
      end
    end
  end

  defp get_pools(name, pool) do
    Registry.lookup(name, Finch.Pool.to_name(pool))
  end

  defp pool(%{port: port}), do: Finch.Pool.from_name({:http, "localhost", port, :default})

  defp expect_any(bypass) do
    Bypass.expect(bypass, fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)
  end

  defmodule PlugFn do
    def init(fun) when is_function(fun, 1) do
      fun
    end

    def call(conn, fun) do
      fun.(conn)
    end
  end

  defp start_server(opts) do
    opts =
      opts
      |> Keyword.put_new(:port, 0)
      |> Keyword.put_new(:scheme, :http)
      |> Keyword.put_new_lazy(:ref, fn ->
        :"test_server_#{System.unique_integer([:positive])}"
      end)
      |> Keyword.update!(:plug, fn
        plug when is_function(plug, 1) ->
          {PlugFn, plug}

        plugs when is_list(plugs) ->
          {PlugFn, &Plug.run(&1, plugs)}

        plug ->
          plug
      end)

    opts =
      if opts[:scheme] == :https do
        opts
        |> Keyword.put_new(:keyfile, "#{__DIR__}/fixtures/selfsigned_key.pem")
        |> Keyword.put_new(:certfile, "#{__DIR__}/fixtures/selfsigned.pem")
      else
        opts
      end

    start_supervised!({Plug.Cowboy, opts})
    "#{opts[:scheme]}://localhost:#{:ranch.get_port(opts[:ref])}"
  end
end
