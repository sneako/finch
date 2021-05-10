defmodule Finch.HTTP2.IntegrationTest do
  use ExUnit.Case, async: false

  alias Finch.HTTP2Server
  alias Finch.TestHelper

  @moduletag :capture_log

  setup_all do
    port = 4002

    {:ok, _} = HTTP2Server.start(port)

    {:ok, url: "https://localhost:#{port}"}
  end

  test "sends http2 requests", %{url: url} do
    start_supervised!(
      {Finch,
       name: TestFinch,
       pools: %{
         default: [
           protocol: :http2,
           count: 5,
           conn_opts: [
             transport_opts: [
               verify: :verify_none
             ]
           ]
         ]
       }}
    )

    assert {:ok, response} = Finch.build(:get, url) |> Finch.request(TestFinch)
    assert response.body == "Hello world!"
  end

  test "sends the query string", %{url: url} do
    start_supervised!(
      {Finch,
       name: TestFinch,
       pools: %{
         default: [
           protocol: :http2,
           count: 5,
           conn_opts: [
             transport_opts: [
               verify: :verify_none
             ]
           ]
         ]
       }}
    )

    query_string = URI.encode_query(test: true, these: "params")
    url = url <> "/query?" <> query_string

    assert {:ok, response} = Finch.build(:get, url) |> Finch.request(TestFinch)
    assert response.body == query_string
  end

  test "multiplexes requests over a single pool", %{url: url} do
    start_supervised!(
      {Finch,
       name: TestFinch,
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

    # We create multiple requests here using a single connection. There is a delay
    # in the response. But because we allow each request to run simultaneously
    # they shouldn't block each other which we check with a rough time estimates
    request = Finch.build(:get, url <> "/wait/1000")

    results =
      1..50
      |> Enum.map(fn _ ->
        Task.async(fn ->
          start = System.monotonic_time()
          {:ok, _} = Finch.request(request, TestFinch)
          System.monotonic_time() - start
        end)
      end)
      |> Enum.map(&Task.await/1)

    for result <- results do
      time = System.convert_time_unit(result, :native, :millisecond)
      assert time <= 1200
    end
  end

  @tag skip: TestHelper.ssl_version() < [10, 2]
  test "writes TLS secrets to SSLKEYLOGFILE file", %{url: url} do
    tmp_dir = System.tmp_dir()
    log_file = Path.join(tmp_dir, "ssl-key-file.log")
    :ok = System.put_env("SSLKEYLOGFILE", log_file)

    start_supervised!(
      {Finch,
       name: TestFinch,
       pools: %{
         default: [
           protocol: :http2,
           count: 5,
           conn_opts: [
             transport_opts: [
               verify: :verify_none,
               keep_secrets: true,
               versions: [:"tlsv1.2", :"tlsv1.3"]
             ]
           ]
         ]
       }}
    )

    try do
      assert {:ok, response} = Finch.build(:get, url) |> Finch.request(TestFinch)
      assert response.body == "Hello world!"
      assert File.stat!(log_file) > 0
    after
      File.rm!(log_file)
      System.delete_env("SSLKEYLOGFILE")
    end
  end
end
