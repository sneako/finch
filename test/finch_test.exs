defmodule FinchTest do
  use ExUnit.Case, async: true
  doctest Finch

  setup do
    {:ok, bypass: Bypass.open()}
  end

  describe "pool configuration" do
    test "unconfigured", %{bypass: bypass} do
      {:ok, _} = Finch.start_link(name: MyFinch)
      expect_any(bypass)

      {:ok, _response} = Finch.request(MyFinch, :get, endpoint(bypass), [], "")
      assert [_pool] = get_pools(MyFinch, shp(bypass))
    end

    test "default can be configured", %{bypass: bypass} do
      {:ok, _} = Finch.start_link(name: MyFinch, pools: %{default: %{count: 5, size: 5}})
      expect_any(bypass)

      {:ok, _response} = Finch.request(MyFinch, :get, endpoint(bypass), [], "")
      pools = get_pools(MyFinch, shp(bypass))
      assert length(pools) == 5
    end

    test "specific scheme, host, port combos can be configurated independently", %{bypass: bypass} do
      other_bypass = Bypass.open()
      default_bypass = Bypass.open()

      Finch.start_link(
        name: MyFinch,
        pools: %{
          shp(bypass) => %{count: 5, size: 5},
          shp(other_bypass) => %{count: 10, size: 10}
        }
      )

      Enum.each([bypass, other_bypass, default_bypass], fn b ->
        expect_any(b)
        Finch.request(MyFinch, :get, endpoint(b), [], "")
      end)

      assert get_pools(MyFinch, shp(bypass)) |> length() == 5
      assert get_pools(MyFinch, shp(other_bypass)) |> length() == 10
      assert get_pools(MyFinch, shp(default_bypass)) |> length() == 1
    end
  end

  describe "timeout" do
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
