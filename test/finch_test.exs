defmodule FinchTest do
  use ExUnit.Case
  doctest Finch

  test "greets the world" do
    assert Finch.hello() == :world
  end
end
