defmodule FinchTest do
  use ExUnit.Case, async: true
  doctest Finch

  alias Finch.Response

  setup do
    {:ok, bypass: Bypass.open()}
  end

  describe "start_link/1" do
    test "raises if :name is not provided" do
      error = assert_raise(ArgumentError, fn -> Finch.start_link([]) end)
      assert error.message =~ "must supply a name"
    end
  end

  describe "pool configuration" do
    test "unconfigured", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass), [], "")
      assert [_pool] = get_pools(MyFinch, shp(bypass))

      {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass), [], "")
    end

    test "default can be configured", %{bypass: bypass} do
      {:ok, _} = Finch.start_link(name: MyFinch, pools: %{default: %{count: 5, size: 5}})
      expect_any(bypass)

      {:ok, %Response{}} = Finch.request(MyFinch, "GET", endpoint(bypass), [], "")
      pools = get_pools(MyFinch, shp(bypass))
      assert length(pools) == 5

      {:ok, %Response{}} = Finch.request(MyFinch, "GET", endpoint(bypass), [], "")
    end

    test "specific scheme, host, port combos can be configurated independently and pools will be started automatically",
         %{bypass: bypass} do
      other_bypass = Bypass.open()
      default_bypass = Bypass.open()

      start_supervised(
        {Finch,
         name: MyFinch,
         pools: %{
           shp(bypass) => %{count: 5, size: 5},
           shp(other_bypass) => %{count: 10, size: 10}
         }}
      )

      assert get_pools(MyFinch, shp(bypass)) |> length() == 5
      assert get_pools(MyFinch, shp(other_bypass)) |> length() == 10

      # no pool has been started for this unconfigured shp
      assert get_pools(MyFinch, shp(default_bypass)) |> length() == 0
    end
  end

  describe "request/5" do
    test "successful post request", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})

      req_body = "{\"response\":\"please\"}"
      response_body = "{\"right\":\"here\"}"
      header_key = "content-type"
      header_val = "application/json"

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        assert {:ok, ^req_body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_header(header_key, header_val)
        |> Plug.Conn.send_resp(200, response_body)
      end)

      assert {:ok, %Response{status: 200, headers: headers, body: ^response_body}} =
               Finch.request(
                 MyFinch,
                 :post,
                 endpoint(bypass),
                 [{header_key, header_val}],
                 req_body
               )

      assert {_, "application/json"} =
               Enum.find(headers, fn
                 {"content-type", _} -> true
                 _ -> false
               end)
    end

    test "properly handles connection: close", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("connection", "close")
        |> Plug.Conn.send_resp(200, "OK")
      end)

      assert {:ok, %Response{status: 200, body: "OK"}} =
               Finch.request(
                 MyFinch,
                 :get,
                 endpoint(bypass),
                 [{"connection", "keep-alive"}]
               )
    end

    test "returns error when request times out", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})

      timeout = 100

      Bypass.expect(bypass, fn conn ->
        Process.sleep(timeout + 50)
        Plug.Conn.send_resp(conn, 200, "delayed")
      end)

      assert {:error, %{reason: :timeout}} =
               Finch.request(MyFinch, :get, endpoint(bypass), [], nil, receive_timeout: timeout)

      assert {:ok, %Response{}} =
               Finch.request(MyFinch, :get, endpoint(bypass), [], nil,
                 receive_timeout: timeout * 2
               )
    end

    test "worker exits when pool times out", %{bypass: bypass} do
      start_supervised({Finch, name: MyFinch})
      expect_any(bypass)

      timeout = 100
      {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass))

      Bypass.down(bypass)

      try do
        Finch.request(MyFinch, :get, endpoint(bypass), [], nil, pool_timeout: timeout)
      catch
        :exit, reason ->
          assert {:timeout, _} = reason
      end

      Bypass.up(bypass)
      assert {:ok, %Response{}} = Finch.request(MyFinch, :get, endpoint(bypass))
    end
  end

  defp get_pools(name, shp) do
    Registry.lookup(name, shp)
  end

  defp endpoint(%{port: port}, path \\ "/"), do: "http://localhost:#{port}#{path}"

  defp shp(%{port: port}), do: {:http, "localhost", port}

  defp expect_any(bypass) do
    Bypass.expect(bypass, fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)
  end
end
