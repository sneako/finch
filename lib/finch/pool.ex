defmodule Finch.Pool do
  @moduledoc false
  # Defines a behaviour that both http1 and http2 pools need to implement.

  @type request_ref :: {reference(), pool :: pid(), pool_mod :: module(), state :: term()}

  @callback request(pid(), Finch.Request.t(), acc, Finch.stream(acc), list()) ::
              {:ok, acc} | {:error, term()}
            when acc: term()

  @callback async_request(pid(), Finch.Request.t(), list()) :: request_ref()

  @callback cancel_async_request(request_ref()) :: :ok

  defguard is_request_ref(ref)
           when tuple_size(ref) == 4 and
                  is_reference(elem(ref, 0)) and
                  is_pid(elem(ref, 1)) and
                  is_atom(elem(ref, 2))
end
