defmodule Finch.HTTP1.IntegrationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Finch.HTTP1Server

  @moduletag :capture_log

  setup_all do
    port = 4001

    {:ok, _} = HTTP1Server.start(port)

    {:ok, url: "https://localhost:#{port}"}
  end

  test "fail to negotiate h2 protocol", %{url: url} do

    start_supervised!({Finch, name: H2Finch, pools: %{
      default: [
        protocol: :http2,
        conn_opts: [
          transport_opts: [
            verify: :verify_none,
          ]
        ]
      ]
    }})

    assert capture_log(fn ->
      {:error, _} = Finch.build(:get, url) |> Finch.request(H2Finch)
    end) =~ "ALPN protocol not negotiated"

  end

end
