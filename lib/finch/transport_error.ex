defmodule Finch.TransportError do
  @moduledoc """
  Represents transport errors returned by Finch.

  `:phase` is `:connect` when an HTTP/1 connection failed to open (DNS,
  TCP, or TLS), so no part of the request was sent and it is safe to retry
  for any method. It is `nil` otherwise, including a timeout or a closed
  socket after the request was sent.
  """

  @type reason() :: Mint.TransportError.reason()

  @type t() :: %__MODULE__{
          reason: reason(),
          source: Mint.TransportError.t() | nil,
          phase: :connect | nil
        }

  defexception [:reason, :source, :phase]

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
