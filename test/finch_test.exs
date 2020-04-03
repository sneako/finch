defmodule FinchTest do
  use ExUnit.Case
  doctest Finch

  defmodule MyFinch do
    use Finch
  end

  describe "get" do
    test "basic example" do
      {:ok, _} = MyFinch.start_link()

      assert {:ok, _response} = MyFinch.request("GET", url(), [], "", [])
      assert {:ok, _response} = MyFinch.request("GET", url(), [], "", [])
    end
  end

  defp url do
    "http://localhost:8080"
  end
end
