defmodule Finch.HTTP2PoolTest do
  use ExUnit.Case, async: false

  alias Finch.HTTP2Server

  test "can open an http2 pool" do
    server = HTTP2Server.start()

    assert {:ok, server} = server

    {:ok, conn} = Finch.HTTP2Conn.start_link()

    results = Finch.HTTP2Conn.multi(conn)

    assert Enum.count(results) == 50
    assert results
    |> Enum.filter(fn {result, _} -> result == :ok end)
    |> Enum.count() == 50
  end
end
