defmodule Finch.HTTP1.IntegrationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Finch.HTTPS1Server
  alias Finch.TestHelper

  setup_all do
    {:ok, listen_socket} = :ssl.listen(0, mode: :binary)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    :ssl.close(listen_socket)

    {:ok, _} = HTTPS1Server.start(port)

    {:ok, url: "https://localhost:#{port}"}
  end

  @tag :capture_log
  test "fail to negotiate h2 protocol", %{url: url} do
    start_supervised!(
      {Finch,
       name: H2Finch,
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

    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "h2-connect-fail",
      [:finch, :connect, :stop],
      fn _, _, %{error: _}, _ -> send(test_pid, ref) end,
      nil
    )

    assert capture_log(fn ->
             {:error, _} = Finch.build(:get, url) |> Finch.request(H2Finch)
             assert_receive ^ref, 5_000
             Logger.flush()
           end) =~ ~r/no application protocol/i

    :telemetry.detach("h2-connect-fail")
  end

  @tag :capture_log
  @tag skip: TestHelper.ssl_version() < [10, 2]
  test "writes TLS secrets to SSLKEYLOGFILE file", %{url: url} do
    tmp_dir = System.tmp_dir()
    log_file = Path.join(tmp_dir, "ssl-key-file.log")
    :ok = System.put_env("SSLKEYLOGFILE", log_file)

    start_finch([:"tlsv1.2", :"tlsv1.3"])

    try do
      assert {:ok, _} = Finch.build(:get, url) |> Finch.request(H1Finch)
      assert File.stat!(log_file).size > 0
    after
      File.rm!(log_file)
      System.delete_env("SSLKEYLOGFILE")
    end
  end

  @tag :capture_log
  @tag skip: TestHelper.ssl_version() < [10, 2]
  test "writes TLS secrets to SSLKEYLOGFILE file using TLS 1.3" do
    tmp_dir = System.tmp_dir()
    log_file = Path.join(tmp_dir, "ssl-key-file.log")
    :ok = System.put_env("SSLKEYLOGFILE", log_file)

    start_finch([:"tlsv1.3"])

    try do
      {:ok, _} = Finch.build(:get, "https://rabbitmq.com") |> Finch.request(H1Finch)
      assert File.stat!(log_file).size > 0
    after
      File.rm!(log_file)
      System.delete_env("SSLKEYLOGFILE")
    end
  end

  @tag :capture_log
  @tag skip: TestHelper.ssl_version() < [10, 2]
  test "cancel streaming response", %{url: url} do
    start_finch([:"tlsv1.2", :"tlsv1.3"])

    assert catch_throw(
             Finch.stream(Finch.build(:get, url), H1Finch, :ok, fn {:status, _}, :ok ->
               throw(:error)
             end)
           ) == :error
  end

  test "trailers" do
    handler = fn transport, socket ->
      data = """
      HTTP/1.1 200 OK
      transfer-encoding: chunked
      trailer: x-foo, x-bar

      6\r
      chunk1\r
      6\r
      chunk2\r
      0\r
      x-foo: foo\r
      x-bar: bar\r
      \r
      """

      :ok = transport.send(socket, data)
    end

    {:ok, %{url: url}} = Finch.MockSocketServer.start(socket: {nil, []}, handler: handler)

    start_supervised!(
      {Finch,
       name: H1Finch,
       pools: %{
         default: [
           protocols: [:http1]
         ]
       }}
    )

    {:ok, resp} = Finch.build(:get, url) |> Finch.request(H1Finch)
    assert resp.status == 200
    assert resp.headers == [{"transfer-encoding", "chunked"}, {"trailer", "x-foo, x-bar"}]
    assert resp.body == "chunk1chunk2"
    assert resp.trailers == [{"x-foo", "foo"}, {"x-bar", "bar"}]
  end

  describe "trailers with an empty chunked body (#408)" do
    test "are emitted as trailers, distinct from repeated header names" do
      events =
        stream_events([
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ntrailer: signature, digest\r\n",
          "signature: initial\r\n\r\n0\r\nsignature: final\r\ndigest: a\r\ndigest: b\r\n\r\n"
        ])

      assert events == [
               {:status, 200},
               {:headers,
                [
                  {"transfer-encoding", "chunked"},
                  {"trailer", "signature, digest"},
                  {"signature", "initial"}
                ]},
               {:trailers, [{"signature", "final"}, {"digest", "a"}, {"digest", "b"}]}
             ]

      {:ok, url} =
        serve(["HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\nx: y\r\n\r\n"])

      {:ok, resp} = Finch.build(:get, url) |> Finch.request(H1Finch)
      assert resp.headers == [{"transfer-encoding", "chunked"}]
      assert resp.body == ""
      assert resp.trailers == [{"x", "y"}]
    end

    test "without trailers emits no trailers event" do
      assert stream_events(["HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n"]) ==
               [{:status, 200}, {:headers, [{"transfer-encoding", "chunked"}]}]
    end

    test "after an informational response" do
      events =
        stream_events([
          "HTTP/1.1 103 Early Hints\r\nlink: </a>\r\n\r\n",
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\nx: y\r\n\r\n"
        ])

      assert events == [
               {:status, 103},
               {:headers, [{"link", "</a>"}]},
               {:status, 200},
               {:headers, [{"transfer-encoding", "chunked"}]},
               {:trailers, [{"x", "y"}]}
             ]
    end

    test "streamed header blocks stay headers" do
      events =
        stream_events(
          [
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n",
            "a: 1\r\n\r\n1\r\nx\r\n0\r\nx: y\r\n\r\n"
          ],
          stream_headers: true
        )

      assert events == [
               {:status, 200},
               {:headers, [{"transfer-encoding", "chunked"}]},
               {:headers, [{"a", "1"}]},
               {:data, "x"},
               {:trailers, [{"x", "y"}]}
             ]
    end
  end

  defp stream_events(packets, conn_opts \\ []) do
    {:ok, url} = serve(packets, conn_opts)

    {:ok, events} =
      Finch.build(:get, url)
      |> Finch.stream_while(H1Finch, [], fn event, acc -> {:cont, [event | acc]} end)

    Enum.reverse(events)
  end

  # Sends each packet separately so streamed headers arrive in distinct reads.
  defp serve(packets, conn_opts \\ []) do
    handler = fn transport, socket ->
      for packet <- packets do
        :ok = transport.send(socket, packet)
        Process.sleep(20)
      end
    end

    {:ok, %{url: url}} = Finch.MockSocketServer.start(socket: {nil, []}, handler: handler)

    if Process.whereis(H1Finch) == nil do
      start_supervised!(
        {Finch, name: H1Finch, pools: %{default: [protocols: [:http1], conn_opts: conn_opts]}}
      )
    end

    {:ok, url}
  end

  defp start_finch(tls_versions) do
    start_supervised!(
      {Finch,
       name: H1Finch,
       pools: %{
         default: [
           protocols: [:http1],
           conn_opts: [
             transport_opts: [
               reuse_sessions: false,
               verify: :verify_none,
               keep_secrets: true,
               versions: tls_versions,
               ciphers: get_ciphers_for_tls_versions(tls_versions)
             ]
           ]
         ]
       }}
    )
  end

  def get_ciphers_for_tls_versions(tls_versions) do
    if TestHelper.ssl_version() >= [8, 2, 4] do
      # Note: :ssl.filter_cipher_suites/2 is available
      tls_versions
      |> List.foldl([], fn v, acc ->
        [:ssl.filter_cipher_suites(:ssl.cipher_suites(:all, v), []) | acc]
      end)
      |> List.flatten()
    else
      :ssl.cipher_suites(:all, :"tlsv1.2")
    end
  end
end
