defmodule FinchTest do
  use ExUnit.Case
  doctest Finch

  describe "get" do
    test "basic example" do
      {:ok, _} = Finch.start_link(name: MyFinch)

      assert {:ok, _response} = Finch.request(MyFinch, "GET", url(), [], "")
      assert {:ok, _response} = Finch.request(MyFinch, "GET", url(), [], "")
    end
  end

  defp url do
    "http://localhost:8080"
  end
end
