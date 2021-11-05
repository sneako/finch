defmodule Finch.RequestTransformer do
  @moduledoc """
  A behaviour for transforming a `Finch.Request` struct just before the actual request is made,
  for example, to inject distributed tracing headers.

  The `transform/2` callback will be called with the following parameters and should return the
  transformed `Finch.Request.t()` struct:

    * `request`: The `Finch.Request.t()` struct representing the request to be transformed.

    * `opts`: the options that were passed to `Finch.stream/5` or `Finch.request/3`, so that the
    transformer can behave differently per request.

  Note that this function will be called synchronously during every request, so care should be
  taken to ensure that it does not introduce unnecessary latency.

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
