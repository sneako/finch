defmodule Finch.RequestTransformer do
  @moduledoc """
  A RequestTransformer behaviour module that specifies a `transform/2` callback that can be used to modify
  Requests as they're being made (for example, to inject distributed tracing headers). Opts is passed
  down from the opts given to `stream/5` or `request/3`, so it may be used to allow the callback to behave
  differently per request. Note that this function will be called synchronously during every request, so care
  should be taken to ensure that it does not introduce unnecessary latency.

  ### Example implementation

      defmodule HeaderInjector do
        @behaviour Finch.RequestTransformer

        def transform(request, _opts) do
          %{request | headers: [{"injected-header", "123"} | request.headers]}
        end
      end
  """

  @callback transform(request :: Finch.Request.t(), opts :: keyword()) :: Finch.Request.t()
end
