defmodule Finch.Error do
  @moduledoc """
  An HTTP error.

  This exception struct is used to represent errors of all sorts for the HTTP/2 protocol.
  """

  @type t() :: %__MODULE__{reason: atom()}

  defexception [:reason]

  @impl true
  def exception(reason) when is_atom(reason) do
    %__MODULE__{reason: reason}
  end

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "#{reason}"
  end
end
