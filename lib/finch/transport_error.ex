defmodule Finch.TransportError do
  @moduledoc """
  Represents transport errors returned by Finch.
  """

  @type t() :: %__MODULE__{reason: term(), source: Mint.TransportError.t() | nil}

  defexception [:reason, :source]

  @doc false
  def from_mint(%Mint.TransportError{reason: reason} = error) do
    %__MODULE__{reason: reason, source: error}
  end

  @impl true
  def message(%__MODULE__{source: %Mint.TransportError{} = source}) do
    Exception.message(source)
  end

  def message(%__MODULE__{reason: reason}) when is_binary(reason), do: reason

  def message(%__MODULE__{reason: reason}) do
    Mint.TransportError.message(%Mint.TransportError{reason: reason})
  end
end
