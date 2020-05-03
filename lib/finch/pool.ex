defmodule Finch.Pool do
  @moduledoc false
  # Defines a behaviour that both http1 and http2 pools need to implement.

  @callback request(pid(), map(), list()) :: {:ok, Finch.Response.t()} | {:error, term()}
end
