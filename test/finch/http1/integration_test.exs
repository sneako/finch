defmodule Finch.HTTP1.IntegrationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  require Logger

  alias Finch.HTTP1Server
  alias Finch.TestHelper

  setup_all do
    port = 4001

    {:ok, _} = HTTP1Server.start(port)

    {:ok, url: "https://localhost:#{port}"}
  end

  @tag :capture_log
  test "fail to negotiate h2 protocol", %{url: url} do
    start_supervised!(
      {Finch,
       name: H2Finch,
       pools: %{
         default: [
           protocol: :http2,
           conn_opts: [
             transport_opts: [
               verify: :verify_none
             ]
           ]
         ]
       }}
    )

    assert capture_log(fn ->
             {:error, _} = Finch.build(:get, url) |> Finch.request(H2Finch)
           end) =~ "ALPN protocol not negotiated"
  end

  @tag :capture_log
  @tag skip: TestHelper.ssl_version() < [10, 2]
  test "writes TLS secrets to SSLKEYLOGFILE file", %{url: url} do
    tmp_dir = System.tmp_dir()
    log_file = Path.join(tmp_dir, "ssl-key-file.log")
    :ok = System.put_env("SSLKEYLOGFILE", log_file)

    start_finch([:"tlsv1.2", :"tlsv1.3"])

    try do
      assert {:ok, _} = Finch.build(:get, url) |> Finch.request(H2Finch)
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
      {:ok, _} = Finch.build(:get, "https://rabbitmq.com") |> Finch.request(H2Finch)
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
             Finch.stream(Finch.build(:get, url), H2Finch, :ok, fn {:status, _}, :ok ->
               throw(:error)
             end)
           ) == :error
  end

  defp start_finch(tls_versions) do
    start_supervised!(
      {Finch,
       name: H2Finch,
       pools: %{
         default: [
           protocol: :http1,
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
