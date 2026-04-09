defmodule Finch.ErrorTest do
  use ExUnit.Case, async: true

  describe "wrap/1" do
    test "returns Mint.TransportError as-is" do
      source = Mint.TransportError.exception(reason: :timeout)
      error = Finch.Error.wrap(source)

      assert %Mint.TransportError{reason: :timeout} = error
      assert error == source
      assert Exception.message(error) == Exception.message(source)
    end

    test "returns Mint.HTTPError as-is" do
      source =
        Mint.HTTPError.exception(
          reason: :too_many_concurrent_requests,
          module: Mint.HTTP2
        )

      error = Finch.Error.wrap(source)

      assert %Mint.HTTPError{reason: :too_many_concurrent_requests, module: Mint.HTTP2} = error
      assert error == source
      assert Exception.message(error) == Exception.message(source)
    end

    test "wraps other reasons as Finch.Error" do
      error = Finch.Error.wrap(:disconnected)

      assert %Finch.Error{reason: :disconnected} = error
      assert Exception.message(error) == "connection is disconnected"
    end
  end
end
