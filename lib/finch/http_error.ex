defmodule Finch.HTTPError do
  @moduledoc """
  Represents HTTP protocol errors returned by Finch.
  """

  alias Mint.{HTTP1, HTTP2}

  @type proxy_reason() ::
          {:proxy,
           HTTP1.error_reason()
           | HTTP2.error_reason()
           | :tunnel_timeout
           | {:unexpected_status, non_neg_integer()}
           | {:unexpected_trailing_responses, list()}}

  @type reason() :: HTTP1.error_reason() | HTTP2.error_reason() | proxy_reason() | term()

  @type t() :: %__MODULE__{
          reason: reason(),
          module: module() | nil,
          source: Mint.HTTPError.t() | nil
        }

  defexception [:reason, :module, :source]

  @doc false
  def from_mint(%Mint.HTTPError{reason: reason, module: module} = error) do
    %__MODULE__{reason: reason, module: module, source: error}
  end

  @impl true
  def message(%__MODULE__{source: %Mint.HTTPError{} = source}) do
    Exception.message(source)
  end

  def message(%__MODULE__{module: module, reason: reason}) when is_atom(module) do
    module.format_error(reason)
  end

  def message(%__MODULE__{reason: reason}) when is_binary(reason), do: reason
  def message(%__MODULE__{reason: reason}), do: inspect(reason)
end
