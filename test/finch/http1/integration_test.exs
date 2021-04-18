defmodule Finch.HTTP1.IntegrationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  require Logger

  alias Finch.HTTP1Server

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

  test "write TLS secrets to SSLKEYLOGFILE file", %{url: url} do
    assert tmp_dir = System.tmp_dir()
    log_file = Path.join(tmp_dir, "ssl-key-file.log")
    Logger.debug("SSLKEYLOGFILE: #{log_file}")

    start_supervised!(
      {Finch,
       name: H2Finch,
       pools: %{
         default: [
           protocol: :http1,
           conn_opts: [
             transport_opts: [
               verify: :verify_none
             ]
           ]
         ]
       }}
    )

    try do
      assert :ok = System.put_env("SSLKEYLOGFILE", log_file)

      assert {:ok, _} = Finch.build(:get, url) |> Finch.request(H2Finch)

      assert {:ok, log_file_stat} = File.stat(log_file)
      assert log_file_stat.size > 0
    after
      File.rm(log_file)
      System.delete_env("SSLKEYLOGFILE")
    end
  end
end
