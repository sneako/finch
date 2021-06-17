defmodule Finch.Error do
  @moduledoc """
  An HTTP error.

  This exception struct is used to represent errors of all sorts for
  the HTTP/2 protocol.

  A `Finch.Error` struct is an exception, so it can be raised as any other exception.

  ## Message representation

  If you want to convert an error reason to a human-friendly message (for example
  for using in logs), you can use `Exception.message/1`:

      iex> {:error, %Finch.Error{} = error} = Mint.HTTP.connect(:http, "badresponse.com", 80)
      iex> Exception.message(error)

  """

  @type proxy_reason() ::
          {:proxy,
           HTTP1.error_reason()
           | HTTP2.error_reason()
           | :tunnel_timeout
           | {:unexpected_status, non_neg_integer()}
           | {:unexpected_trailing_responses, list()}}

  @type t() :: %__MODULE__{
          reason: HTTP1.error_reason() | HTTP2.error_reason() | proxy_reason() | term()
        }

  defexception [:reason]

  def message(%__MODULE__{reason: reason, module: module}) do
    module.format_error(reason)
  end
end
