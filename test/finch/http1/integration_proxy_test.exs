defmodule Finch.HTTP1.IntegrationProxyTest do
  use ExUnit.Case, async: false

  alias Finch.HTTP1Server

  setup_all do
    {:ok, listen_socket} = :ssl.listen(0, mode: :binary)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    :ssl.close(listen_socket)

    # Not quite a proper forward proxy server, but good enough
    {:ok, _} = HTTP1Server.start(port)

    {:ok, proxy_port: port}
  end

  test "requests HTTP through a proxy", %{proxy_port: proxy_port} do
    start_finch(proxy_port)

    assert {:ok, _} = Finch.build(:get, "http://example.com") |> Finch.request(ProxyFinch)
  end

  defp start_finch(proxy_port) do
    start_supervised!(
      {Finch,
       name: ProxyFinch,
       pools: %{
         default: [
           protocols: [:http1],
           conn_opts: [
             proxy: {:http, "localhost", proxy_port, []}
           ]
         ]
       }}
    )
  end
end
