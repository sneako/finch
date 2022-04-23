defmodule Finch.RequestTest do
  use ExUnit.Case, async: true

  describe "put_private/3" do
    test "accepts atoms as keys" do
      request =
        Finch.build(:get, "http://example.com")
        |> Finch.Request.put_private(:my_lib_key, :foo)

      assert request.private == %{my_lib_key: :foo}
    end

    test "appends to the map when called multiple times" do
      request =
        Finch.build(:get, "http://example.com")
        |> Finch.Request.put_private(:my_lib_key, :foo)
        |> Finch.Request.put_private(:my_lib_key2, :bar)

      assert request.private == %{my_lib_key: :foo, my_lib_key2: :bar}
    end

    test "raises when invalid key is used" do
      assert_raise ArgumentError,
                   """
                   got unsupported private metadata key "my_key"
                   only atoms are allowed as keys of the `:private` field.
                   """,
                   fn ->
                     Finch.build(:get, "http://example.com")
                     |> Finch.Request.put_private("my_key", :foo)
                   end
    end
  end
end
