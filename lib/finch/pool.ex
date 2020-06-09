defmodule Finch.Pool do
  @moduledoc false
  # Defines a behaviour that both http1 and http2 pools need to implement.
  @callback request(pid(), Finch.Request.t(), acc, Finch.stream(acc), list()) ::
              {:ok, acc} | {:error, term()}
            when acc: term()
end
