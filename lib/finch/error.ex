defmodule Finch.Error do
  @moduledoc """
  An HTTP error.

  This exception struct is used to represent errors returned by Finch that are not
  transport or HTTP protocol errors.
  """

  @type reason() :: atom() | String.t() | term()

  @type t() :: %__MODULE__{reason: reason()}

  defexception [:reason]

  @impl true
  def exception(reason) do
    %__MODULE__{reason: reason}
  end

  @impl true
  def message(%__MODULE__{reason: reason}) when is_binary(reason), do: reason
  def message(%__MODULE__{reason: reason}) when is_atom(reason), do: format_reason(reason)
  def message(%__MODULE__{reason: reason}), do: inspect(reason)

  defp format_reason(:connection_process_went_down), do: "connection process went down"
  defp format_reason(:connection_closed), do: "connection closed"
  defp format_reason(:disconnected), do: "connection is disconnected"
  defp format_reason(:request_timeout), do: "request timed out"
  defp format_reason(:read_only), do: "connection is closed for writing"
  defp format_reason(:could_not_connect), do: "could not connect"
  defp format_reason(:connection_dead), do: "connection is dead"
  defp format_reason(reason), do: Atom.to_string(reason)

  @doc false
  @spec wrap(term()) :: Finch.Error.t() | Finch.HTTPError.t() | Finch.TransportError.t()
  def wrap(%Finch.Error{} = error), do: error
  def wrap(%Finch.HTTPError{} = error), do: error
  def wrap(%Finch.TransportError{} = error), do: error
  def wrap(%Mint.HTTPError{} = error), do: Finch.HTTPError.from_mint(error)
  def wrap(%Mint.TransportError{} = error), do: Finch.TransportError.from_mint(error)
  def wrap(reason), do: exception(reason)
end
