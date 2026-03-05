defmodule Finch.Pool.StrategyTest do
  use ExUnit.Case, async: true

  alias Finch.Pool.Strategy.Random
  alias Finch.Pool.Strategy.RoundRobin
  alias Finch.Pool.Strategy.Hash

  defmodule FakePool do
    def select(entries, n) do
      Enum.at(entries, n)
    end
  end

  defp distinct_entries(n) do
    pids = for _ <- 1..n, do: spawn(fn -> :ok end)
    for pid <- pids, do: {pid, FakePool}
  end

  describe "Random" do
    test "new/0 returns nil" do
      assert Random.new() == nil
    end

    test "select/2 returns one of the entries" do
      entries = distinct_entries(3)
      state = Random.new()

      results = for _ <- 1..50, do: Random.select(entries, state)
      unique = Enum.uniq(results)

      # Over many runs we should see more than one entry (probabilistic)
      assert [_ | _] = unique
      assert Enum.all?(results, fn r -> r in entries end)
    end
  end

  describe "RoundRobin" do
    test "new/0 returns an atomics ref" do
      ref = RoundRobin.new()
      assert is_reference(ref)
    end

    test "select/2 cycles through entries in order" do
      entries = distinct_entries(3)
      counter = RoundRobin.new()

      first = RoundRobin.select(entries, counter)
      second = RoundRobin.select(entries, counter)
      third = RoundRobin.select(entries, counter)
      fourth = RoundRobin.select(entries, counter)

      idx = fn entry -> Enum.find_index(entries, &(&1 == entry)) end

      assert idx.(fourth) == idx.(first)
      assert idx.(first) != idx.(second) or length(entries) == 1
      assert [first, second, third] |> Enum.uniq() |> length() == 3
    end
  end

  describe "Hash" do
    test "new/0 returns self" do
      assert Hash.new() == self()
    end

    test "new/1 returns the key as state" do
      assert Hash.new(:my_key) == :my_key
      assert Hash.new("team_123") == "team_123"
    end

    test "select/2 same key always selects same worker" do
      entries = distinct_entries(5)
      key = :team_42

      a = Hash.select(entries, key)
      b = Hash.select(entries, key)

      assert a == b
    end

    test "select/2 different keys distribute across workers" do
      entries = distinct_entries(5)
      keys = [:a, :b, :c, :d, :e]

      selected = for key <- keys, do: Hash.select(entries, key)
      unique = Enum.uniq(selected)

      assert length(unique) >= 2
    end

    test "select/2 index is deterministic from key and pool size" do
      # phash2(key, 3) gives 0, 1, or 2
      entries = distinct_entries(3)
      idx = :erlang.phash2(:foo, 3)
      expected = Enum.at(entries, idx)
      assert Hash.select(entries, :foo) == expected
    end
  end
end
