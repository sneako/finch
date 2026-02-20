defmodule Finch.HTTP2.PoolTest do
  use ExUnit.Case

  import Mint.HTTP2.Frame

  alias Finch.HTTP2.Pool
  alias Finch.MockHTTP2Server

  defmacrop assert_recv_frames(frames) when is_list(frames) do
    quote do: unquote(frames) = recv_next_frames(unquote(length(frames)))
  end

  @moduletag :capture_log

  setup do
    start_supervised({Registry, keys: :unique, name: :test})

    request = %{
      scheme: :https,
      method: "GET",
      path: "/",
      query: nil,
      host: "localhost",
      port: nil,
      headers: [],
      body: nil
    }

    {:ok, request: request}
  end

  def start_pool(port, pool_opts \\ []) do
    defaults =
      %{
        conn_opts: [transport_opts: [verify: :verify_none]],
        start_pool_metrics?: false,
        count: 1,
        wait_for_server_settings?: false,
        ping_interval: :infinity
      }

    pool = Finch.Pool.from_name({:https, "localhost", port, :default})
    config = Enum.into(pool_opts, defaults)
    Pool.start_link({pool, :pool_name, :test, config, 1})
  end

  describe "requests" do
    test "request/response", %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        {:ok, resp} = request(pool, req, [])
        send(us, {:resp, {:ok, resp}})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
        data(stream_id: stream_id, data: "hello to you", flags: set_flags(:data, [:end_stream]))
      ])

      assert_receive {:resp, {:ok, {200, [], "hello to you"}}}
    end

    test "errors such as :max_header_list_size_reached are returned to the caller", %{
      request: req
    } do
      server_settings = [max_header_list_size: 5]

      {:ok, pool} =
        start_server_and_connect_with([server_settings: server_settings], fn port ->
          start_pool(port)
        end)

      assert {:error, error, _acc} = request(pool, %{req | headers: [{"foo", "bar"}]}, [])
      assert %{reason: {:max_header_list_size_exceeded, _, _}} = error
    end

    test "if server sends GOAWAY and then replies, we get the replies but are closed for writing",
         %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        result = request(pool, req, [])
        send(us, {:resp, result})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      # Force the connection to enter read only mode
      server_send_frames([
        goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "all good")
      ])

      :timer.sleep(10)

      # We can't send any more requests since the connection is closed for writing.
      assert {:error, %Finch.Error{reason: :read_only}, _acc} = request(pool, req, [])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
        data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
      ])

      assert_receive {:resp, {:ok, {200, [], "hello"}}}

      # If the server now closes the socket, we actually shut down.
      :ok = :ssl.close(server_socket())

      Process.sleep(50)

      # If we try to make a request now that the server shut down, we get an error.
      assert {:error, %Finch.Error{reason: :disconnected}, _acc} = request(pool, req, [])
    end

    test "if server disconnects while there are waiting clients, we notify those clients", %{
      request: req
    } do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        result = request(pool, req, [])
        send(us, {:resp, result})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers]))
      ])

      :ok = :ssl.close(server_socket())

      assert_receive {:resp, {:error, %Finch.Error{reason: :connection_closed}, _acc}}
    end

    test "if connections reaches max concurrent streams, we return an error", %{request: req} do
      server_settings = [max_concurrent_streams: 1]

      {:ok, pool} =
        start_server_and_connect_with([server_settings: server_settings], fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        request(pool, req, [])
      end)

      assert_recv_frames([headers(stream_id: _stream_id)])

      assert {:error, %Mint.HTTPError{reason: :too_many_concurrent_requests}, _acc} =
               request(pool, req, [])
    end

    test "with wait_for_server_settings: true, request fails with :connection_not_ready until SETTINGS applied then succeeds",
         %{request: req} do
      us = self()
      server_opts = [defer_settings: true, server_settings: [max_concurrent_streams: 1]]
      pool_opts = [wait_for_server_settings?: true]

      # Server defers sending SETTINGS so the client stays in :handshaking until we send them.
      {:ok, pool} =
        start_server_and_connect_with(server_opts, fn port ->
          start_pool(port, pool_opts)
        end)

      # First request: server has not sent SETTINGS yet, so we get only the error (no request is sent).
      assert {:error, %Finch.Error{reason: :connection_not_ready}, _acc} = request(pool, req, [])

      # Now send server SETTINGS; the client will receive and apply them.
      server_send_settings()

      # Second request must succeed.
      spawn(fn -> send(us, {:result, request(pool, req, [])}) end)
      assert_recv_frames([headers(stream_id: stream_id)])
      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
        data(stream_id: stream_id, data: "ok", flags: set_flags(:data, [:end_stream]))
      ])

      assert_receive {:result, {:ok, {200, [], "ok"}}}
    end

    test "request timeout with timeout of 0", %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        resp = request(pool, req, receive_timeout: 0)
        send(us, {:resp, resp})
      end)

      assert_recv_frames([headers(stream_id: stream_id), rst_stream(stream_id: stream_id)])

      assert_receive {:resp, {:error, %Finch.Error{reason: :request_timeout}, _acc}}
    end

    test "request timeout with timeout > 0", %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        resp = request(pool, req, receive_timeout: 50)
        send(us, {:resp, resp})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers]))
      ])

      assert_receive {:resp, {:error, %Finch.Error{reason: :request_timeout}, _acc}}
    end

    test "request timeout with timeout > 0 that fires after request is done", %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        resp = request(pool, req, receive_timeout: 50)
        send(us, {:resp, resp})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      server_send_frames([
        headers(
          stream_id: stream_id,
          hbf: server_encode_headers([{":status", "200"}]),
          flags: set_flags(:headers, [:end_headers, :end_stream])
        )
      ])

      assert_receive {:resp, {:ok, _}}
      refute_receive _any, 200
    end

    test "request timeout with timeout > 0 where :done arrives after timeout", %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        resp = request(pool, req, receive_timeout: 10)
        send(us, {:resp, resp})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      # We sleep enough so that the timeout fires, then we send a response.
      Process.sleep(30)

      server_send_frames([
        headers(
          stream_id: stream_id,
          hbf: server_encode_headers([{":status", "200"}]),
          flags: set_flags(:headers, [:end_headers, :end_stream])
        )
      ])

      # When there's a timeout, we cancel the request.
      assert_recv_frames([rst_stream(stream_id: ^stream_id, error_code: :cancel)])

      assert_receive {:resp, {:error, %Finch.Error{reason: :request_timeout}, _acc}}
    end
  end

  describe "async requests" do
    test "sends responses to the caller", %{test: finch_name} do
      start_finch!(finch_name)
      {:ok, url} = start_server!()

      request_ref =
        Finch.build(:get, url)
        |> Finch.async_request(finch_name)

      assert_receive {^request_ref, {:status, 200}}, 300
      assert_receive {^request_ref, {:headers, headers}} when is_list(headers)
      assert_receive {^request_ref, {:data, "Hello world!"}}
      assert_receive {^request_ref, :done}
    end

    test "sends errors to the caller", %{test: finch_name} do
      start_finch!(finch_name)
      {:ok, url} = start_server!()

      request_ref =
        Finch.build(:get, url <> "/wait/100")
        |> Finch.async_request(finch_name, receive_timeout: 10)

      assert_receive {^request_ref, {:error, %{reason: :request_timeout}}}, 300
    end

    test "canceled with cancel_async_request/1", %{test: finch_name} do
      start_finch!(finch_name)
      {:ok, url} = start_server!()

      ref =
        Finch.build(:get, url <> "/stream/1/50")
        |> Finch.async_request(finch_name)

      assert_receive {^ref, {:status, 200}}
      Finch.HTTP2.Pool.cancel_async_request(ref)
      refute_receive _
    end

    test "canceled if calling process exits normally", %{test: finch_name} do
      start_finch!(finch_name)
      {:ok, url} = start_server!()

      outer = self()

      caller =
        spawn(fn ->
          ref =
            Finch.build(:get, url <> "/stream/5/500")
            |> Finch.async_request(finch_name)

          # allow process to exit normally after sending
          send(outer, ref)
        end)

      assert_receive {Finch.HTTP2.Pool, {pool, _}} = ref

      assert {_, %{refs: %{^ref => _}}} = :sys.get_state(pool)

      Process.sleep(100)
      refute Process.alive?(caller)

      assert {_, %{refs: refs}} = :sys.get_state(pool)
      assert refs == %{}
    end

    test "canceled if calling process exits abnormally", %{test: finch_name} do
      start_finch!(finch_name)
      {:ok, url} = start_server!()

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

      assert_receive {Finch.HTTP2.Pool, {pool, _}} = ref

      assert {_, %{refs: %{^ref => _}}} = :sys.get_state(pool)

      Process.exit(caller, :shutdown)
      Process.sleep(100)
      refute Process.alive?(caller)

      assert {_, %{refs: refs}} = :sys.get_state(pool)
      assert refs == %{}
    end

    test "if server sends GOAWAY and then replies, we get the replies but are closed for writing",
         %{request: req} do
      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      ref = Pool.async_request(pool, req, nil, [])

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      # Force the connection to enter read only mode
      server_send_frames([
        goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "all good")
      ])

      :timer.sleep(10)

      # We can't send any more requests since the connection is closed for writing.
      ref2 = Pool.async_request(pool, req, nil, [])
      assert_receive {^ref2, {:error, %Finch.Error{reason: :read_only}}}

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
        data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
      ])

      assert_receive {^ref, {:status, 200}}
      assert_receive {^ref, {:headers, []}}
      assert_receive {^ref, {:data, "hello"}}

      # If the server now closes the socket, we actually shut down.
      :ok = :ssl.close(server_socket())

      Process.sleep(50)

      # If we try to make a request now that the server shut down, we get an error.
      ref3 = Pool.async_request(pool, req, nil, [])
      assert_receive {^ref3, {:error, %Finch.Error{reason: :disconnected}}}
    end

    test "if server disconnects while there are waiting clients, we notify those clients", %{
      request: req
    } do
      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      ref = Pool.async_request(pool, req, nil, [])

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers]))
      ])

      assert_receive {^ref, {:status, 200}}
      assert_receive {^ref, {:headers, []}}

      :ok = :ssl.close(server_socket())

      assert_receive {^ref, {:error, %Finch.Error{reason: :connection_closed}}}
    end

    test "errors such as :max_header_list_size_reached are returned to the caller", %{
      request: req
    } do
      server_settings = [max_header_list_size: 5]

      {:ok, pool} =
        start_server_and_connect_with([server_settings: server_settings], fn port ->
          start_pool(port)
        end)

      ref = Pool.async_request(pool, %{req | headers: [{"foo", "bar"}]}, nil, [])

      assert_receive {^ref, {:error, %{reason: {:max_header_list_size_exceeded, _, _}}}}
    end

    defp start_finch!(finch_name) do
      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocols: [:http2],
             count: 5,
             conn_opts: [
               transport_opts: [
                 verify: :verify_none
               ]
             ]
           ]
         }}
      )
    end

    defp start_server! do
      {:ok, Application.get_env(:finch, :test_https_h2_url)}
    end
  end

  describe "ping_interval" do
    test "sends PING frames at the configured interval" do
      {:ok, _pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port, ping_interval: 50)
        end)

      # Should receive a PING frame one interval after another
      assert_recv_frames([ping()])
      assert_recv_frames([ping()])
    end

    test "does not send PINGs when interval is :infinity" do
      {:ok, _pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port, ping_interval: :infinity)
        end)

      # Wait a bit and verify no PING is received
      refute_receive {:ssl, _, _}, 100
    end

    test "responds to pong without error", %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port, ping_interval: 50)
        end)

      # Receive the PING and send a PONG back
      assert_recv_frames([ping(opaque_data: data)])
      server_send_frames([ping(stream_id: 0, flags: set_flags(:ping, [:ack]), opaque_data: data)])

      # Pool should still be functional - send a request
      spawn(fn ->
        {:ok, resp} = request(pool, req, [])
        send(us, {:resp, {:ok, resp}})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
        data(stream_id: stream_id, data: "ok", flags: set_flags(:data, [:end_stream]))
      ])

      assert_receive {:resp, {:ok, {200, [], "ok"}}}
    end
  end

  describe "idle ping reset" do
    test "ping timer resets on request activity", %{request: req} do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port, ping_interval: 50)
        end)

      # Send a request at 25ms, which should reset the ping timer
      Process.sleep(25)

      spawn(fn ->
        {:ok, resp} = request(pool, req, [])
        send(us, {:resp, {:ok, resp}})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
        data(stream_id: stream_id, data: "ok", flags: set_flags(:data, [:end_stream]))
      ])

      assert_receive {:resp, {:ok, {200, [], "ok"}}}

      # Record the time after the response was received
      activity_time = System.monotonic_time(:millisecond)

      # The PING should arrive >50ms after the last activity (the response).
      # If the timer hadn't been reset, it would have fired earlier (>50ms after connect).
      assert ping() = receive_ping_frame()

      ping_time = System.monotonic_time(:millisecond)
      elapsed = ping_time - activity_time

      # The PING should have arrived after at least ~100ms (allowing some slack from the 50ms interval)
      assert elapsed >= 50, "PING arrived too early (#{elapsed}ms), timer was not reset"
    end
  end

  describe "on-demand ping" do
    test "returns RTT on success" do
      us = self()

      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      spawn(fn ->
        result = Pool.ping(pool)
        send(us, {:ping_result, result})
      end)

      assert_recv_frames([ping(opaque_data: data)])

      server_send_frames([ping(stream_id: 0, flags: set_flags(:ping, [:ack]), opaque_data: data)])
      assert_receive {:ping_result, {:ok, rtt}}
      assert is_integer(rtt)
      assert rtt >= 0
    end

    test "returns error when disconnected" do
      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      # Close the server to force disconnection, sleep just to yield the process
      :ok = :ssl.close(server_socket())
      Process.sleep(1)

      assert {:error, %Finch.Error{reason: :disconnected}} = Pool.ping(pool)
    end

    test "returns error when read_only" do
      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      us = self()

      # Start a request to keep a pending stream
      spawn(fn ->
        result =
          request(
            pool,
            %{
              scheme: :https,
              method: "GET",
              path: "/",
              query: nil,
              host: "localhost",
              port: nil,
              headers: [],
              body: nil
            },
            []
          )

        send(us, {:resp, result})
      end)

      assert_recv_frames([headers(stream_id: stream_id)])

      # Send GOAWAY to enter read_only state
      server_send_frames([
        goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "bye")
      ])

      Process.sleep(1)

      assert {:error, %Finch.Error{reason: :read_only}} = Pool.ping(pool)

      # Complete the pending request to clean up
      hbf = server_encode_headers([{":status", "200"}])

      server_send_frames([
        headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
        data(stream_id: stream_id, data: "ok", flags: set_flags(:data, [:end_stream]))
      ])

      assert_receive {:resp, {:ok, _}}
    end

    test "pending pings fail on disconnect" do
      {:ok, pool} =
        start_server_and_connect_with(fn port ->
          start_pool(port)
        end)

      us = self()

      spawn(fn ->
        result = Pool.ping(pool)
        send(us, {:ping_result, result})
      end)

      # Wait for the PING frame to arrive
      assert_recv_frames([ping()])

      # Close server to force disconnect (don't send PONG)
      :ok = :ssl.close(server_socket())

      assert_receive {:ping_result, {:error, %Finch.Error{reason: :connection_closed}}}
    end
  end

  @pdict_key {__MODULE__, :http2_test_server}

  defp request(pool, req, opts) do
    acc = {nil, [], ""}

    fun = fn
      {:status, value}, {_, headers, body} -> {:cont, {value, headers, body}}
      {:headers, value}, {status, headers, body} -> {:cont, {status, headers ++ value, body}}
      {:data, value}, {status, headers, body} -> {:cont, {status, headers, body <> value}}
    end

    Pool.request(pool, req, acc, fun, nil, opts)
  end

  defp start_server_and_connect_with(opts \\ [], fun) do
    {result, server} = MockHTTP2Server.start_and_connect_with(opts, fun)

    Process.put(@pdict_key, server)

    result
  end

  defp recv_next_frames(n) do
    server = Process.get(@pdict_key)
    MockHTTP2Server.recv_next_frames(server, n)
  end

  defp server_encode_headers(headers) do
    server = Process.get(@pdict_key)
    {server, hbf} = MockHTTP2Server.encode_headers(server, headers)
    Process.put(@pdict_key, server)
    hbf
  end

  defp server_send_frames(frames) do
    server = Process.get(@pdict_key)
    :ok = MockHTTP2Server.send_frames(server, frames)
  end

  defp server_socket() do
    server = Process.get(@pdict_key)
    MockHTTP2Server.get_socket(server)
  end

  defp server_send_settings() do
    server = Process.get(@pdict_key)
    :ok = MockHTTP2Server.send_server_settings(server)
  end

  # Receive frames from server socket, skipping non-PING frames (e.g. WINDOW_UPDATE).
  # Returns the first PING frame found.
  defp receive_ping_frame do
    server = Process.get(@pdict_key)
    receive_ping_frame(server, "")
  end

  defp receive_ping_frame(%{socket: server_socket} = server, buffer) do
    data =
      case buffer do
        "" ->
          assert_receive {:ssl, ^server_socket, data}, 500
          data

        _ ->
          buffer
      end

    case Mint.HTTP2.Frame.decode_next(data) do
      {:ok, ping(opaque_data: _) = frame, _rest} ->
        frame

      {:ok, _other_frame, rest} ->
        receive_ping_frame(server, rest)

      :more ->
        assert_receive {:ssl, ^server_socket, more_data}, 500
        receive_ping_frame(server, data <> more_data)
    end
  end
end
