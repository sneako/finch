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
  A body associated with a response.
  """
  @type body() :: binary() | nil

  @type t :: %Response{
          status: Mint.Types.status(),
          body: body(),
          headers: Mint.Types.headers()
        }
end
