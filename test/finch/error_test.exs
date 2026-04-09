defmodule Finch.ErrorTest do
  use ExUnit.Case, async: true

  describe "wrap/1" do
    test "wraps Mint.TransportError as Finch.TransportError" do
      source = Mint.TransportError.exception(reason: :timeout)
      error = Finch.Error.wrap(source)

      assert %Finch.TransportError{reason: :timeout, source: ^source} = error
      assert Exception.message(error) == Exception.message(source)
    end

    test "wraps Mint.HTTPError as Finch.HTTPError" do
      source =
        Mint.HTTPError.exception(
          reason: :too_many_concurrent_requests,
          module: Mint.HTTP2
        )

      error = Finch.Error.wrap(source)

      assert %Finch.HTTPError{
               reason: :too_many_concurrent_requests,
               module: Mint.HTTP2,
               source: ^source
             } = error

      assert Exception.message(error) == Exception.message(source)
    end

    test "wraps other reasons as Finch.Error" do
      error = Finch.Error.wrap(:disconnected)

      assert %Finch.Error{reason: :disconnected} = error
      assert Exception.message(error) == "connection is disconnected"
    end
  end
end
