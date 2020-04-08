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

  @typedoc """
  A body associated with a response.
  """
  @type body() :: binary() | nil

  @typedoc """
  HTTP response headers.

  Headers are received as lists of two-element tuples containing two strings,
  the header name and header value.
  """
  @type headers() :: [{header_name :: String.t(), header_value :: String.t()}]

  @type t :: %Response{
          status: status(),
          body: body(),
          headers: headers()
        }
end
