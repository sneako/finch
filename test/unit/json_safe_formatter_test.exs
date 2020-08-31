defmodule LoggerJSON.JasonSafeFormatterTest do
  use Logger.Case, async: true

  alias LoggerJSON.JasonSafeFormatter, as: Formatter

  defmodule IDStruct, do: defstruct(id: nil)

  describe "format/1" do
    test "allows nils" do
      assert nil == Formatter.format(nil)
    end

    test "allows booleans" do
      assert true == Formatter.format(true)
      assert false == Formatter.format(false)
    end

    test "allows printable strings" do
      assert "hello" == Formatter.format("hello")
    end

    test "inspects non-printable binaries" do
      assert "<<104, 101, 108, 108, 111, 0>>" == Formatter.format("hello" <> <<0>>)
    end

    test "allows atoms" do
      assert :hello == Formatter.format(:hello)
    end

    test "allows numbers" do
      assert 123 == Formatter.format(123)
    end

    test "strips Structs" do
      assert %{id: "hello"} == Formatter.format(%IDStruct{id: "hello"})
    end

    test "converts tuples to lists" do
      assert [1, 2, 3] == Formatter.format({1, 2, 3})
    end

    test "converts Keyword lists to maps" do
      assert %{a: 1, b: 2} == Formatter.format(a: 1, b: 2)
    end

    test "inspects functions" do
      assert "&LoggerJSON.JasonSafeFormatter.format/1" == Formatter.format(&Formatter.format/1)
    end

    test "inspects pids" do
      assert inspect(self()) == Formatter.format(self())
    end

    test "doesn't choke on things that look like keyword lists but aren't" do
      assert [%{a: 1}, [:b, 2, :c]] == Formatter.format([{:a, 1}, {:b, 2, :c}])
    end

    test "formats nested structures" do
      input = %{
        foo: [
          foo_a: %{"x" => 1, "y" => %IDStruct{id: 1}},
          foo_b: [foo_b_1: 1, foo_b_2: {"2a", "2b"}]
        ],
        self: self()
      }

      assert %{
               foo: %{
                 foo_a: %{"x" => 1, "y" => %{id: 1}},
                 foo_b: %{foo_b_1: 1, foo_b_2: %{"2a" => "2b"}}
               },
               self: inspect(self())
             } == Formatter.format(input)
    end
  end
end
