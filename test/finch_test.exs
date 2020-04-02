defmodule FinchTest do
  use ExUnit.Case
  doctest Finch

  describe "get" do
    test "basic example" do
      assert {:ok, _response} = Finch.request("GET", url(), [], "", [])
      assert {:ok, _response} = Finch.request("GET", url(), [], "", [])
    end
  end

  defp url do
    "http://localhost:8080"
  end
end
