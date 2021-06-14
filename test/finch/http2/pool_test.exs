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
      body: nil,
    }

    {:ok, request: request}
  end

  def start_pool(port) do
    Pool.start_link({{:https, "localhost", port}, :test, 0, conn_opts: [transport_opts: [verify: :verify_none]]})
  end

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

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
      data(stream_id: stream_id, data: "hello to you", flags: set_flags(:data, [:end_stream]))
    ])

    assert_receive {:resp, {:ok, {200, [], "hello to you"}}}
  end

  test "errors such as :max_header_list_size_reached are returned to the caller", %{request: req} do
    server_settings = [max_header_list_size: 5]

    {:ok, pool} =
      start_server_and_connect_with([server_settings: server_settings], fn port ->
        start_pool(port)
      end)

    assert {:error, error} = request(pool, %{req | headers: [{"foo", "bar"}]}, [])
    assert %{reason: {:max_header_list_size_exceeded, _, _}} = error
  end

  test "if server sends GOAWAY and then replies, we get the replies but are closed for writing", %{request: req} do
    us = self()
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        start_pool(port)
      end)

    spawn(fn ->
      result = request(pool, req, [])
      send(us, {:resp, result})
    end)

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    # Force the connection to enter read only mode
    server_send_frames([
      goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "all good"),
    ])

    :timer.sleep(10)

    # We can't send any more requests since the connection is closed for writing.
    assert {:error, %{reason: :read_only}} = request(pool, req, [])

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
      data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
    ])

    assert_receive {:resp, {:ok, {200, [], "hello"}}}

    # If the server now closes the socket, we actually shut down.
    :ok = :ssl.close(server_socket())

    Process.sleep(50)

    # If we try to make a request now that the server shut down, we get an error.
    assert {:error, %{reason: :disconnected}} = request(pool, req, [])
  end

  test "errors are not always {:error, Mint.Types.error()}", %{request: req} do
    us = self()
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        start_pool(port)
      end)

    spawn(fn ->
      result = request(pool, req, [])
      send(us, {:resp, result})
    end)

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    # Force the connection to enter read only mode
    server_send_frames([
      goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "all good"),
    ])

    :timer.sleep(10)

    # We can't send any more requests since the connection is closed for writing.
    assert {:error, %{reason: :read_only}=error_read_only} = request(pool, req, [])
    Exception.message(error_read_only)

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
      data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
    ])

    assert_receive {:resp, {:ok, {200, [], "hello"}}}

    # If the server now closes the socket, we actually shut down.
    :ok = :ssl.close(server_socket())

    Process.sleep(50)

    # If we try to make a request now that the server shut down, we get an error.
    assert {:error, %{reason: :disconnected}=error_disconnected} = request(pool, req, [])
    Exception.message(error_disconnected)
  end

  test "if server disconnects while there are waiting clients, we notify those clients", %{request: req} do
    us = self()
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        start_pool(port)
      end)

    spawn(fn ->
      result = request(pool, req, [])
      send(us, {:resp, result})
    end)

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers]))
    ])

    :ok = :ssl.close(server_socket())

    assert_receive {:resp, {:error, %{reason: :connection_closed}}}
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

    assert_recv_frames [headers(stream_id: _stream_id)]

    assert {:error, %{reason: :too_many_concurrent_requests}} = request(pool, req, [])
  end

  test "request timeout with timeout of 0", %{request: req} do
    us = self()

    {:ok, pool} = start_server_and_connect_with(fn port ->
      start_pool(port)
    end)

    spawn(fn ->
      resp = request(pool, req, receive_timeout: 0)
      send(us, {:resp, resp})
    end)

    assert_recv_frames [headers(stream_id: stream_id), rst_stream(stream_id: stream_id)]

    assert_receive {:resp, {:error, %{reason: :request_timeout}}}
  end

  test "request timeout with timeout > 0", %{request: req} do
    us = self()

    {:ok, pool} = start_server_and_connect_with(fn port ->
      start_pool(port)
    end)

    spawn(fn ->
      resp = request(pool, req, receive_timeout: 50)
      send(us, {:resp, resp})
    end)

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers]))
    ])

    assert_receive {:resp, {:error, %{reason: :request_timeout}}}
  end

  test "request timeout with timeout > 0 that fires after request is done", %{request: req} do
    us = self()
    {:ok, pool} = start_server_and_connect_with(fn port ->
      start_pool(port)
    end)

    spawn(fn ->
      resp = request(pool, req, receive_timeout: 50)
      send(us, {:resp, resp})
    end)

    assert_recv_frames [headers(stream_id: stream_id)]

    server_send_frames([
      headers(
        stream_id: stream_id,
        hbf: server_encode_headers([{":status", "200"}]),
        flags: set_flags(:headers, [:end_headers, :end_stream])
      )
    ])

    assert_receive {:resp, {:ok, _}}

    assert_recv_frames [rst_stream(stream_id: ^stream_id, error_code: :no_error)]

    refute_receive _any, 200
  end

  test "request timeout with timeout > 0 where :done arrives after timeout", %{request: req} do
    us = self()
    {:ok, pool} = start_server_and_connect_with(fn port ->
      start_pool(port)
    end)

    spawn(fn ->
      resp = request(pool, req, receive_timeout: 10)
      send(us, {:resp, resp})
    end)

    assert_recv_frames [headers(stream_id: stream_id)]

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
    assert_recv_frames [rst_stream(stream_id: ^stream_id, error_code: :cancel)]

    assert_receive {:resp, {:error, %{reason: :request_timeout}}}
  end

  @pdict_key {__MODULE__, :http2_test_server}

  defp request(pool, req, opts) do
    acc = {nil, [], ""}

    fun = fn
      {:status, value}, {_, headers, body} -> {value, headers, body}
      {:headers, value}, {status, headers, body} -> {status, headers ++ value, body}
      {:data, value}, {status, headers, body} -> {status, headers, body <> value}
    end

    Pool.request(pool, req, acc, fun, opts)
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
end

