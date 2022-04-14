defmodule Finch.RequestTest do
  use ExUnit.Case, async: true

  describe "put_private/3" do
    test "pass valid metadata" do
      request =
        Finch.build(:get, "http://example.com")
        |> Finch.Request.put_private(:my_lib_key, :foo)

      assert request.private == %{my_lib_key: :foo}

      request = Finch.Request.put_private(request, :my_lib_key2, :bar)

      assert request.private == %{my_lib_key: :foo, my_lib_key2: :bar}
    end

    test "raises when invalid metadata is passed" do
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
