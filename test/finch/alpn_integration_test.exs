defmodule Finch.ALPNIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup_all do
    {:ok, listen_socket} = :ssl.listen(0, mode: :binary)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    :ssl.close(listen_socket)

    {:ok, _} = Finch.ALPNServer.start(port)

    {:ok, url: "https://localhost:#{port}"}
  end

  # This test reproduces issue #265 where sending POST requests with bodies larger than 64KB
  # fails when using protocols: [:http1, :http2] due to HTTP/2 window size constraints.
  # The HTTP/1 pool doesn't implement HTTP/2 flow control, causing the request to exceed
  # the HTTP/2 window size (65535 bytes).
  @tag :skip
  test "POST request with body larger than 64KB using ALPN negotiation", %{url: url} do
    # Start Finch with ALPN negotiation (both HTTP/1 and HTTP/2)
    start_supervised!(
      {Finch,
       name: ALPNFinch,
       pools: %{
         default: [
           protocols: [:http1, :http2],
           conn_opts: [
             transport_opts: [
               verify: :verify_none
             ]
           ]
         ]
       }}
    )

    # Create a body larger than 64KB (65538 bytes as per issue)
    large_body = :crypto.strong_rand_bytes(65_538)

    # This should fail with {:exceeds_window_size, :request, 65535}
    # when the connection upgrades to HTTP/2 via ALPN
    result =
      Finch.build(:post, "#{url}/echo", [], large_body)
      |> Finch.request(ALPNFinch)

    # Currently this fails with the window size error
    # Once fixed, this should succeed
    case result do
      {:ok, response} ->
        assert response.status == 200
        body = Jason.decode!(response.body)
        assert body["received_bytes"] == 65_538

      {:error, %Mint.HTTPError{reason: {:exceeds_window_size, :request, 65_535}}} ->
        flunk("""
        Request failed with window size error - this is the bug we're trying to fix.
        The HTTP/1 pool doesn't implement HTTP/2 flow control when connections upgrade via ALPN.
        """)

      {:error, error} ->
        flunk("Unexpected error: #{inspect(error)}")
    end
  end

  # Test that confirms HTTP/2-only works correctly with large bodies
  test "POST request with body larger than 64KB using HTTP/2 only (should work)", %{url: url} do
    start_supervised!(
      {Finch,
       name: HTTP2Finch,
       pools: %{
         default: [
           protocols: [:http2],
           conn_opts: [
             transport_opts: [
               verify: :verify_none
             ]
           ]
         ]
       }}
    )

    large_body = :crypto.strong_rand_bytes(65_538)

    {:ok, response} =
      Finch.build(:post, "#{url}/echo", [], large_body)
      |> Finch.request(HTTP2Finch)

    assert response.status == 200
    body = Jason.decode!(response.body)
    assert body["received_bytes"] == 65_538
  end

  # Test that confirms HTTP/1-only works correctly with large bodies
  test "POST request with body larger than 64KB using HTTP/1 only (should work)", %{url: url} do
    start_supervised!(
      {Finch,
       name: HTTP1Finch,
       pools: %{
         default: [
           protocols: [:http1],
           conn_opts: [
             transport_opts: [
               verify: :verify_none
             ]
           ]
         ]
       }}
    )

    large_body = :crypto.strong_rand_bytes(65_538)

    {:ok, response} =
      Finch.build(:post, "#{url}/echo", [], large_body)
      |> Finch.request(HTTP1Finch)

    assert response.status == 200
    body = Jason.decode!(response.body)
    assert body["received_bytes"] == 65_538
  end
end
