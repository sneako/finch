defmodule Finch.Response do
  @moduledoc """
  A response to a request.
  """

  alias __MODULE__

  defstruct [
    :status,
    :body,
    headers: []
  ]

  @typedoc """
  An HTTP status code.

  The type for an HTTP is a generic non-negative integer since we don't formally check that
  the response code is in the "common" range (`200..599`).
  """
  @type status() :: non_neg_integer()

  @type t :: %Response{
          status: status(),
          body: Finch.body(),
          headers: Finch.headers()
        }
end
