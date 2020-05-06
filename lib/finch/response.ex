defmodule Finch.Response do
  @moduledoc """
  A response to a request.
  """

  alias __MODULE__

  defstruct [
    :status,
    body: "",
    headers: []
  ]

  @type t :: %Response{
          status: Mint.Types.status(),
          body: binary(),
          headers: Mint.Types.headers()
        }
end
