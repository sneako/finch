defmodule Finch.Error do
  @moduledoc """
  An HTTP error.

  This exception struct is used to represent errors of all sorts for
  the HTTP/2 protocol.

  A `Finch.Error` struct is an exception, so it can be raised as any other exception.

  ## Message representation

  If you want to convert an error reason to a human-friendly message (for example
  for using in logs), you can use `Exception.message/1`:

      iex> {:error, %Finch.Error{} = error} = request...
      iex> Exception.message(error)

  """

  @type t() :: %__MODULE__{reason: atom()}

  defexception [:reason]

  @impl true
  def exception(reason) do
    %__MODULE__{reason: reason}
  end

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "error: #{inspect(reason)}"
  end
end
